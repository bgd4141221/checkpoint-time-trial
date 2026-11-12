-- Discord: bgden8694 | Roblox: boggdd12
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- TimeTrialBootstrap starts this controller on the server. Heartbeat moves the bars
-- and checks each runner's position. The controller saves progress in a Run record
-- and publishes the values the HUD needs through attributes on that Player.
type RunStatus = "Ready" | "Racing" | "Finished"
type Gate = { part: BasePart, index: number, respawn: CFrame }
type Spinner = { part: BasePart, origin: CFrame, speed: number }
type Run = {
	status: RunStatus,
	checkpoint: number,
	startedAt: number,
	finishedTime: number,
	best: number,
	deaths: number,
	splits: { number },
	lastGateAt: number,
	lastRestartAt: number,
	lastPosition: Vector3?,
	lastSampleAt: number,
	insideStart: boolean,
	generation: number,
	connections: { RBXScriptConnection },
	deathConnection: RBXScriptConnection?,
}

-- Aim for one player sample every 0.05 seconds to limit the number of volume checks.
-- The bars move every Heartbeat so they still look smooth between samples.
local SAMPLE_INTERVAL = 1 / 20
local RESTART_COOLDOWN = 1
local MAX_HORIZONTAL_SPEED = 48
local POSITION_ALLOWANCE = 12
-- Give the bar check some room for the character's body around the root part.
local BODY_MARGIN = Vector3.new(0.75, 2, 0.75)
local Controller = {}
-- Each player has their own run. Their best time lasts until they leave this server.
local runs: { [Player]: Run } = {}
local connections: { RBXScriptConnection } = {}
local gates: { [number]: Gate } = {}
local spinners: { Spinner } = {}
local course: Model
local lobby: BasePart
local remote: RemoteEvent?
local finishIndex = 0
local running = false
local accumulator = 0
local motionEpoch = 0

local function disconnectAll(list: { RBXScriptConnection }): ()
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

local function setMessage(player: Player, message: string): ()
	player:SetAttribute("TrialMessage", message)
end

-- Send a snapshot when race state changes. While racing, the HUD subtracts
-- TrialStartedAt from GetServerTimeNow() locally, so there's no timer update to
-- replicate each frame. After FINISH it displays the server's TrialFinalTime.
local function publish(player: Player, run: Run): ()
	player:SetAttribute("TrialStatus", run.status)
	player:SetAttribute("TrialCheckpoint", run.checkpoint)
	player:SetAttribute("TrialStartedAt", run.startedAt)
	player:SetAttribute("TrialFinalTime", run.finishedTime)
	player:SetAttribute("TrialBest", run.best)
	player:SetAttribute("TrialDeaths", run.deaths)
	-- START is index 0 and FINISH is the highest index. Only the gates between them count.
	player:SetAttribute("TrialCheckpointCount", finishIndex - 1)
	-- The array holds cumulative times in gate order. An empty array means no split yet.
	player:SetAttribute("TrialLastSplit", run.splits[#run.splits] or 0)
end

-- A character can be missing its root during a respawn. Skip the position check
-- until there is a living humanoid and a root to sample.
local function getLivingRoot(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return nil, nil
	end
	return root, humanoid
end

local function contains(part: BasePart, position: Vector3, margin: Vector3): boolean
	-- Convert the world position into coordinates relative to the part's center and axes.
	-- The same box check then works even when a sweeper has rotated since the last sample.
	local point = part.CFrame:PointToObjectSpace(position)
	-- From the center, each face is half the part's size away. Check both sides of
	-- each axis with math.abs(). Bars get extra space for the body, while gates use zero margin.
	local halfSize = part.Size * 0.5 + margin
	return math.abs(point.X) <= halfSize.X
		and math.abs(point.Y) <= halfSize.Y
		and math.abs(point.Z) <= halfSize.Z
end

local function respawnFrame(run: Run): CFrame
	if run.status == "Racing" then
		-- The gate's Respawn attribute gives us a position and facing on the course.
		-- Index 0 gives a runner who hasn't reached checkpoint 1 a place to return to.
		return gates[run.checkpoint].respawn
	end
	-- Raise the root above the lobby marker and turn it a quarter turn around local Y.
	return lobby.CFrame * CFrame.new(0, 3.5, 0) * CFrame.Angles(0, -math.pi / 2, 0)
end

local function moveToCheckpoint(player: Player, run: Run): ()
	local root = getLivingRoot(player)
	if not root then
		return
	end
	root.CFrame = respawnFrame(run)
	-- Clear the old fall or spin so it doesn't carry over to the respawn.
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	-- Respawning moves the player instantly, so start the movement check from here.
	run.lastPosition = root.Position
	run.lastSampleAt = Workspace:GetServerTimeNow()
end

local function beginRun(player: Player, run: Run, now: number): ()
	run.status = "Racing"
	run.checkpoint = 0
	run.startedAt = now
	run.finishedTime = 0
	run.deaths = 0
	-- Entering START is the first gate event. Use its timestamp for both the total
	-- run clock and the travel-time check from START to checkpoint 1.
	run.lastGateAt = now
	table.clear(run.splits)
	setMessage(player, "Run started. Reach each checkpoint in order.")
	publish(player, run)
end

local function restartRun(player: Player, run: Run): ()
	local now = Workspace:GetServerTimeNow()
	-- Check this on the server too, since the client can send repeated requests.
	if now - run.lastRestartAt < RESTART_COOLDOWN then
		return
	end
	run.lastRestartAt = now
	run.status = "Ready"
	run.checkpoint = 0
	run.startedAt = 0
	run.finishedTime = 0
	run.deaths = 0
	run.insideStart = false
	table.clear(run.splits)
	-- Change the state to Ready before moving the player. respawnFrame then picks
	-- the lobby instead of a course gate. Keep best in the same Run record.
	moveToCheckpoint(player, run)
	setMessage(player, "Walk through START to begin. Your session best is kept.")
	publish(player, run)
end

local function finishRun(player: Player, run: Run, now: number): ()
	-- Freeze the result at the server sample that accepted FINISH. Changing the
	-- status also takes this player out of the racing checks in samplePlayer.
	run.status = "Finished"
	run.finishedTime = now - run.startedAt
	-- Zero is the initial value before this player has finished a run this session.
	local improved = run.best == 0 or run.finishedTime < run.best
	if improved then
		run.best = run.finishedTime
	end
	setMessage(player, if improved then "New session best! Restart to race again." else "Course complete! Restart to try again.")
	publish(player, run)
end

local function visitGate(player: Player, run: Run, gate: Gate, now: number): ()
	-- The next index is the only one that can advance the run. This also ignores
	-- repeated samples inside the checkpoint the player has already saved.
	if run.status ~= "Racing" or gate.index ~= run.checkpoint + 1 then
		return
	end
	-- Estimate a fast crossing using the distance between gate centers divided by
	-- the allowed speed. Compare that with the time since the last accepted gate.
	-- This catches obvious instant skips, using gate centers as an approximation.
	local previous = gates[run.checkpoint]
	local minimumTravelTime = (gate.part.Position - previous.part.Position).Magnitude / MAX_HORIZONTAL_SPEED
	if now - run.lastGateAt < minimumTravelTime then
		setMessage(player, "Checkpoint reached too quickly. Return to your last checkpoint.")
		moveToCheckpoint(player, run)
		return
	end
	-- Update the timestamp only after validation so a rejected gate can't become
	-- the starting point of the next travel-time check.
	run.lastGateAt = now
	-- Splits are measured from START, rather than from the previous checkpoint.
	table.insert(run.splits, now - run.startedAt)
	if gate.index == finishIndex then
		finishRun(player, run, now)
	else
		run.checkpoint = gate.index
		setMessage(player, string.format("Checkpoint %d saved. The timer continues after a fall.", gate.index))
		publish(player, run)
	end
end

local function samplePlayer(player: Player, run: Run, now: number): ()
	local root, humanoid = getLivingRoot(player)
	if not root or not humanoid then
		return
	end
	-- A fall uses Roblox's normal death/respawn flow. The next CharacterAdded
	-- callback uses the Run record to decide where the new character should land.
	if root.Position.Y < course:GetAttribute("FallHeight") then
		humanoid.Health = 0
		return
	end
	-- Compare this sample with the previous one to detect entering START. Only
	-- Ready players can start a run, so walking back through START can't reset the clock.
	local startInside = contains(gates[0].part, root.Position, Vector3.zero)
	if startInside and not run.insideStart and run.status == "Ready" then
		beginRun(player, run, now)
	end
	run.insideStart = startInside
	if run.status ~= "Racing" then
		return
	end
	if run.lastPosition then
		local delta = root.Position - run.lastPosition
		-- Ignore changes in height so jumps and falls don't use up the horizontal allowance.
		local horizontalDistance = Vector2.new(delta.X, delta.Z).Magnitude
		-- Speed times elapsed seconds gives a distance in studs. Add a fixed buffer
		-- because character positions can arrive unevenly over the network.
		local allowed = POSITION_ALLOWANCE + MAX_HORIZONTAL_SPEED * (now - run.lastSampleAt)
		if horizontalDistance > allowed then
			setMessage(player, "Large movement detected. Returned to your saved checkpoint.")
			moveToCheckpoint(player, run)
			return
		end
	end
	run.lastPosition = root.Position
	run.lastSampleAt = now
	-- Resolve hazards before checkpoints. If both checks would hit on this sample,
	-- the death takes priority and the runner keeps the previously saved gate.
	for _, spinner in spinners do
		if contains(spinner.part, root.Position, BODY_MARGIN) then
			humanoid.Health = 0
			return
		end
	end
	for index = 1, finishIndex do
		local gate = gates[index]
		if contains(gate.part, root.Position, Vector3.zero) then
			-- Reaching a later gate sends the player back. visitGate handles the
			-- expected gate and ignores old ones, so standing in a gate can't record extra splits.
			if index > run.checkpoint + 1 then
				setMessage(player, "Checkpoints must be reached in order.")
				moveToCheckpoint(player, run)
			else
				visitGate(player, run, gate, now)
			end
			break
		end
	end
end

local function onCharacter(player: Player, run: Run, character: Model): ()
	-- Give each spawn a new generation so a task still waiting on the last
	-- character can tell when a newer CharacterAdded callback has taken over.
	run.generation += 1
	local generation = run.generation
	if run.deathConnection then
		run.deathConnection:Disconnect()
		run.deathConnection = nil
	end
	task.spawn(function(): ()
		local humanoid = character:WaitForChild("Humanoid", 10)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		-- Both waits can yield. Recheck the Run and character before touching the
		-- new root in case the player reset, left, or the controller stopped.
		if runs[player] ~= run or run.generation ~= generation or player.Character ~= character then
			return
		end
		if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
			return
		end
		run.deathConnection = humanoid.Died:Connect(function(): ()
			if run.status == "Racing" then
				-- Leave startedAt alone so dying doesn't reset the timer.
				run.deaths += 1
				setMessage(player, "Respawning at your checkpoint. The clock is still running.")
				publish(player, run)
			end
		end)
		-- Death didn't clear the run. Move the new character using the checkpoint
		-- and race state that are current now, after the wait for its parts.
		moveToCheckpoint(player, run)
	end)
end

local function addPlayer(player: Player): ()
	if runs[player] then
		return
	end
	local run: Run = {
		status = "Ready", checkpoint = 0, startedAt = 0, finishedTime = 0,
		best = 0, deaths = 0, splits = {}, lastGateAt = 0, lastRestartAt = -math.huge,
		lastPosition = nil, lastSampleAt = 0, insideStart = false, generation = 0,
		connections = {}, deathConnection = nil,
	}
	runs[player] = run
	publish(player, run)
	setMessage(player, "Walk through START to begin. Jump over red sweepers.")
	table.insert(run.connections, player.CharacterAdded:Connect(function(character: Model): ()
		onCharacter(player, run, character)
	end))
	if player.Character then
		onCharacter(player, run, player.Character)
	end
end

local function removePlayer(player: Player): ()
	local run = runs[player]
	if not run then
		return
	end
	-- Invalidate any spawn task that's still waiting for character parts.
	run.generation += 1
	disconnectAll(run.connections)
	if run.deathConnection then
		run.deathConnection:Disconnect()
	end
	runs[player] = nil
end

local function loadCourse(): ()
	course = Workspace:WaitForChild("TimeTrialCourse") :: Model
	lobby = course:WaitForChild("LobbySpawn") :: BasePart
	for _, instance in (course:WaitForChild("Gates")):GetChildren() do
		assert(instance:IsA("BasePart"), "Every gate must be a BasePart")
		local index = instance:GetAttribute("Index")
		local respawn = instance:GetAttribute("Respawn")
		assert(typeof(index) == "number" and index >= 0 and index % 1 == 0, "Invalid gate index")
		assert(typeof(respawn) == "CFrame", "Gate needs a Respawn CFrame")
		assert(gates[index] == nil, "Duplicate gate index")
		-- Key by the authored Index attribute so course order is independent of Explorer order.
		gates[index] = { part = instance, index = index, respawn = respawn }
		finishIndex = math.max(finishIndex, index)
	end
	assert(finishIndex >= 2 and typeof(course:GetAttribute("FallHeight")) == "number", "Invalid course configuration")
	-- visitGate expects checkpoint + 1 to exist until FINISH. Catch gaps at startup
	-- instead of discovering a missing gate midway through someone's race.
	for index = 0, finishIndex do
		assert(gates[index], "Gate indices must be consecutive, starting at zero")
	end
	for _, instance in (course:WaitForChild("Spinners")):GetChildren() do
		assert(instance:IsA("BasePart"), "Spinner must be a BasePart")
		local speed = instance:GetAttribute("AngularSpeed")
		assert(typeof(speed) == "number", "Spinner needs AngularSpeed in radians per second")
		table.insert(spinners, { part = instance, origin = instance.CFrame, speed = speed })
	end
end

function Controller.Start(): ()
	if running then
		return
	end
	loadCourse()
	running = true
	motionEpoch = Workspace:GetServerTimeNow()
	local restart = Instance.new("RemoteEvent")
	restart.Name = "TimeTrialRestart"
	restart.Parent = ReplicatedStorage
	remote = restart
	-- The HUD sends a restart request with no race data. OnServerEvent supplies
	-- the sending Player, so the server picks the run and applies its own cooldown.
	table.insert(connections, restart.OnServerEvent:Connect(function(player: Player): ()
		local run = runs[player]
		if run then
			restartRun(player, run)
		end
	end))
	table.insert(connections, Players.PlayerAdded:Connect(addPlayer))
	table.insert(connections, Players.PlayerRemoving:Connect(removePlayer))
	-- Start can run after players have already joined. addPlayer checks for an
	-- existing run so this pass and PlayerAdded can't install duplicate listeners.
	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end
	table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime: number): ()
		local now = Workspace:GetServerTimeNow()
		for _, spinner in spinners do
			-- Elapsed seconds times radians per second gives the angle around local Y.
			-- Multiply by the original CFrame so each update keeps the same pivot
			-- and a slow frame doesn't make the bar fall behind.
			spinner.part.CFrame = spinner.origin * CFrame.Angles(0, (now - motionEpoch) * spinner.speed, 0)
		end
		accumulator += deltaTime
		if accumulator < SAMPLE_INTERVAL then
			return
		end
		-- Keep the time left over after removing whole sample intervals. After a
		-- slow frame we check once because we only have the current positions.
		accumulator %= SAMPLE_INTERVAL
		for player, run in runs do
			samplePlayer(player, run, now)
		end
	end))
end

function Controller.Stop(): ()
	if not running then
		return
	end
	running = false
	-- Stop the frame and player callbacks before clearing the state they read.
	disconnectAll(connections)
	for player in runs do
		removePlayer(player)
	end
	for _, spinner in spinners do
		spinner.part.CFrame = spinner.origin
	end
	if remote then
		remote:Destroy()
		remote = nil
	end
	table.clear(gates)
	table.clear(spinners)
	finishIndex = 0
	accumulator = 0
end

return Controller
