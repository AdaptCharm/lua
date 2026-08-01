type Config = {
	enabled: boolean,
	autoClearCacheOnDisable: boolean,
	radius: number,
	height: number,
	rotationSpeed: number,
	attractionStrength: number,
	maxPartsPerFrame: number,
}

type WallAPI = {
	enable: () -> (),
	disable: () -> (),
	toggle: () -> (),
	destroy: () -> (),
}

type Environment = {
	config: Config?,
	lastToLeaveBox: WallAPI?,
}

declare function getgenv(): Environment

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if LocalPlayer == nil then
	return
end

local DEFAULT_CONFIG: Config = {
	enabled = true,
	autoClearCacheOnDisable = false,
	radius = 40,
	height = 100,
	rotationSpeed = 10,
	attractionStrength = 1000,
	maxPartsPerFrame = 10000,
}

local SEGMENT_LENGTH = 5
local WALL_THICKNESS = 2
local WALL_COLOR = Color3.fromRGB(255, 90, 90)
local TOGGLE_KEY = Enum.KeyCode.RightShift

local function resolveNumber(value: any, fallback: number): number
	if typeof(value) ~= "number" then
		return fallback
	end

	return value
end

local function resolveBoolean(value: any, fallback: boolean): boolean
	if typeof(value) ~= "boolean" then
		return fallback
	end

	return value
end

-- The user config is read once, at load, and every field falls back to
-- its default independently, so a partial config table is fine.
local function resolveConfig(): Config
	local userConfig = getgenv().config

	return {
		enabled = resolveBoolean(userConfig and userConfig.enabled, DEFAULT_CONFIG.enabled),
		autoClearCacheOnDisable = resolveBoolean(userConfig and userConfig.autoClearCacheOnDisable, DEFAULT_CONFIG.autoClearCacheOnDisable),
		radius = math.max(resolveNumber(userConfig and userConfig.radius, DEFAULT_CONFIG.radius), 1),
		height = math.max(resolveNumber(userConfig and userConfig.height, DEFAULT_CONFIG.height), 1),
		rotationSpeed = resolveNumber(userConfig and userConfig.rotationSpeed, DEFAULT_CONFIG.rotationSpeed),
		attractionStrength = math.max(resolveNumber(userConfig and userConfig.attractionStrength, DEFAULT_CONFIG.attractionStrength), 0),
		maxPartsPerFrame = math.max(resolveNumber(userConfig and userConfig.maxPartsPerFrame, DEFAULT_CONFIG.maxPartsPerFrame), 1),
	}
end

local function findRootPart(character: Model): BasePart?
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart ~= nil and rootPart:IsA("BasePart") then
		return rootPart :: BasePart
	end

	return nil
end

local function currentCenter(): Vector3
	local character = LocalPlayer.Character
	if character == nil then
		return Vector3.zero
	end

	local rootPart = findRootPart(character)
	if rootPart == nil then
		return Vector3.zero
	end

	return Vector3.new(rootPart.Position.X, 0, rootPart.Position.Z)
end

local function ringPartCount(radius: number): number
	return math.max(1, math.ceil((math.tau * radius) / SEGMENT_LENGTH))
end

-- Builds one wall segment around the origin. The wall is positioned and
-- rotated as a whole later, so segments only need their local CFrame.
local function buildRingPart(radius: number, height: number, index: number, total: number): BasePart
	local angle = (index / total) * math.tau
	local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
	local position = offset + Vector3.new(0, height / 2, 0)

	local part = Instance.new("Part")
	part.Name = "RingSegment"
	part.Size = Vector3.new(SEGMENT_LENGTH, height, WALL_THICKNESS)
	part.CFrame = CFrame.lookAt(position, position + offset.Unit)
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = WALL_COLOR

	return part
end

local function newPrimaryPart(): BasePart
	local primaryPart = Instance.new("Part")
	primaryPart.Anchored = true
	primaryPart.Transparency = 1
	primaryPart.CanCollide = false
	primaryPart.CanTouch = false
	primaryPart.CanQuery = false
	primaryPart.Size = Vector3.new(1, 1, 1)

	return primaryPart
end

local function createWall(config: Config): WallAPI
	local ringModel = Instance.new("Model")
	ringModel.Name = "LastToLeaveBoxWall"
	ringModel.Parent = Workspace

	local connections: { RBXScriptConnection } = {}
	local velocities: { [Player]: BodyVelocity? } = {}

	local buildConnection: RBXScriptConnection? = nil
	local rotationConnection: RBXScriptConnection? = nil

	local active = false
	local destroyed = false
	local angle = 0

	local function clearVelocities()
		for _, velocity in velocities do
			if velocity ~= nil then
				velocity:Destroy()
			end
		end

		table.clear(velocities)
	end

	local function trackVelocitiesFor(player: Player)
		if player == LocalPlayer then
			return
		end

		table.insert(connections, player.CharacterRemoving:Connect(function()
			local velocity = velocities[player]
			if velocity ~= nil then
				velocity:Destroy()
				velocities[player] = nil
			end
		end))
	end

	for _, player in Players:GetPlayers() do
		trackVelocitiesFor(player)
	end

	table.insert(connections, Players.PlayerAdded:Connect(trackVelocitiesFor))

	local function applyAttraction()
		if config.attractionStrength <= 0 then
			return
		end

		local center = currentCenter()
		local pullRange = config.radius * 2

		for _, player in Players:GetPlayers() do
			if player == LocalPlayer then
				continue
			end

			local character = player.Character
			if character == nil then
				continue
			end

			local rootPart = findRootPart(character)
			if rootPart == nil then
				continue
			end

			local offset = rootPart.Position - center
			local distance = offset.Magnitude
			if distance < 1 or distance > pullRange then
				local velocity = velocities[player]
				if velocity ~= nil then
					velocity:Destroy()
					velocities[player] = nil
				end

				continue
			end

			local velocity = velocities[player]
			if velocity == nil then
				velocity = Instance.new("BodyVelocity")
				velocity.MaxForce = Vector3.new(config.attractionStrength, 0, config.attractionStrength)
				velocity.Parent = rootPart
				velocities[player] = velocity
			end

			-- Aim at the nearest point on the ring so they slam into the wall.
			local ringPoint = center + (offset / distance) * config.radius
			local pullDirection = (ringPoint - rootPart.Position).Unit
			velocity.Velocity = pullDirection * (config.attractionStrength / 10)
		end
	end

	local function rotateAndAttract(dt: number)
		angle += math.rad(config.rotationSpeed) * dt
		ringModel:PivotTo(CFrame.new(currentCenter()) * CFrame.Angles(0, angle, 0))
		applyAttraction()
	end

	local function start()
		if destroyed or active or buildConnection ~= nil then
			return
		end

		angle = 0
		ringModel:ClearAllChildren()

		local primaryPart = newPrimaryPart()
		primaryPart.Parent = ringModel
		ringModel.PrimaryPart = primaryPart

		local totalParts = ringPartCount(config.radius)
		local created = 0

		local build = RunService.Heartbeat:Connect(function()
			local batchEnd = math.min(created + config.maxPartsPerFrame, totalParts)

			while created < batchEnd do
				local part = buildRingPart(config.radius, config.height, created, totalParts)
				part.Parent = ringModel
				created += 1
			end

			if created >= totalParts then
				build:Disconnect()
				buildConnection = nil

				ringModel:PivotTo(CFrame.new(currentCenter()))
				rotationConnection = RunService.Heartbeat:Connect(rotateAndAttract)
				active = true
			end
		end)
		buildConnection = build
	end

	local function stop()
		if destroyed then
			return
		end

		if buildConnection ~= nil then
			buildConnection:Disconnect()
			buildConnection = nil
		end

		if rotationConnection ~= nil then
			rotationConnection:Disconnect()
			rotationConnection = nil
		end

		active = false

		if config.autoClearCacheOnDisable then
			ringModel:ClearAllChildren()
			clearVelocities()
		end
	end

	local function teardown()
		if destroyed then
			return
		end

		stop()
		destroyed = true

		ringModel:Destroy()
		clearVelocities()

		for _, connection in connections do
			connection:Disconnect()
		end
	end

	local function toggle()
		if active then
			stop()
		else
			start()
		end
	end

	-- The character is never blocked by its own wall.
	table.insert(connections, RunService.Stepped:Connect(function()
		local character = LocalPlayer.Character
		if character == nil then
			return
		end

		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
	end))

	-- Roblox kicks idle players, so nudge the input system to stay put.
	table.insert(connections, LocalPlayer.Idled:Connect(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.zero)
	end))

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.KeyCode == TOGGLE_KEY then
			toggle()
		end
	end))

	return {
		enable = start,
		disable = stop,
		toggle = toggle,
		destroy = teardown,
	}
end

-- Re-running the script replaces the previous instance instead of
-- stacking a second one on top.
local previousAPI = getgenv().lastToLeaveBox
if previousAPI ~= nil then
	previousAPI.destroy()
end

-- Clean up walls left behind by older versions that had no API.
for _, model in Workspace:GetChildren() do
	if model:IsA("Model") and model.Name == "LastToLeaveBoxWall" then
		model:Destroy()
	end
end

local config = resolveConfig()
local wallAPI = createWall(config)
getgenv().lastToLeaveBox = wallAPI

if config.enabled then
	wallAPI.enable()
end
