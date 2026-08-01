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

type StatusPanel = {
	setStatus: (text: string) -> (),
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
local WALL_MODEL_NAME = "LastToLeaveBoxWall"
local VELOCITY_NAME = "WallPull"

-- Shared state between the wall and the status panel.
local wallState = {
	active = false,
	partCount = 0,
}

local statusPanelAPI: StatusPanel? = nil
local boundAPI: WallAPI? = nil

local function reportStatus(text: string)
	if statusPanelAPI ~= nil then
		statusPanelAPI.setStatus(text)
	end

	warn("[LastToLeaveBox]", text)
end

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

-- The wall model is looked up by name instead of holding a reference.
-- If the server rejects a client-created model, it is destroyed, and a
-- stale reference would throw on every frame. A fresh lookup simply
-- returns nil and we treat that as "the wall is gone".
local function findWallModel(): Model?
	local model = Workspace:FindFirstChild(WALL_MODEL_NAME)
	if model ~= nil and model:IsA("Model") then
		return model :: Model
	end

	return nil
end

local function createWall(config: Config): WallAPI
	local connections: { RBXScriptConnection } = {}

	local buildConnection: RBXScriptConnection? = nil
	local rotationConnection: RBXScriptConnection? = nil

	local active = false
	local destroyed = false
	local angle = 0
	local forceRejectCount = 0
	local reportedForceRejection = false

	local function setWallState(nowActive: boolean, partCount: number)
		wallState.active = nowActive
		wallState.partCount = partCount
	end

	local function handleWallRemoved()
		if not active then
			return
		end

		active = false
		setWallState(false, 0)

		if rotationConnection ~= nil then
			rotationConnection:Disconnect()
			rotationConnection = nil
		end

		if buildConnection ~= nil then
			buildConnection:Disconnect()
			buildConnection = nil
		end

		reportStatus("The wall was removed by the game — this server rejects client-created parts.")
	end

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
				local velocity = rootPart:FindFirstChild(VELOCITY_NAME)
				if velocity ~= nil then
					velocity:Destroy()
				end

				continue
			end

			-- The force is also looked up fresh: if the server keeps
			-- destroying it, we stop creating it and say so.
			local velocity = rootPart:FindFirstChild(VELOCITY_NAME) :: BodyVelocity?
			if velocity == nil then
				forceRejectCount += 1

				if forceRejectCount > 10 then
					if not reportedForceRejection then
						reportedForceRejection = true
						reportStatus("The pull force keeps getting rejected — the wall is not affecting other players.")
					end

					continue
				end

				velocity = Instance.new("BodyVelocity")
				velocity.Name = VELOCITY_NAME
				velocity.MaxForce = Vector3.new(config.attractionStrength, 0, config.attractionStrength)
				velocity.Parent = rootPart
			else
				forceRejectCount = 0
			end

			-- Aim at the nearest point on the ring so they slam into the wall.
			local ringPoint = center + (offset / distance) * config.radius
			local pullDirection = (ringPoint - rootPart.Position).Unit
			velocity.Velocity = pullDirection * (config.attractionStrength / 10)
		end
	end

	local function rotateAndAttract(dt: number)
		local model = findWallModel()
		if model == nil then
			handleWallRemoved()
			return
		end

		angle += math.rad(config.rotationSpeed) * dt
		model:PivotTo(CFrame.new(currentCenter()) * CFrame.Angles(0, angle, 0))
		applyAttraction()
	end

	local function start()
		if destroyed or active or buildConnection ~= nil then
			return
		end

		angle = 0
		forceRejectCount = 0
		reportedForceRejection = false

		local previous = findWallModel()
		if previous ~= nil then
			previous:Destroy()
		end

		local model = Instance.new("Model")
		model.Name = WALL_MODEL_NAME

		local primaryPart = newPrimaryPart()
		primaryPart.Parent = model
		model.PrimaryPart = primaryPart
		model.Parent = Workspace

		local totalParts = ringPartCount(config.radius)
		local created = 0

		local build = RunService.Heartbeat:Connect(function()
			-- A rejected model disappears from Workspace; checking by name
			-- avoids touching a destroyed instance.
			if Workspace:FindFirstChild(WALL_MODEL_NAME) ~= model then
				build:Disconnect()
				buildConnection = nil
				reportStatus("The wall was rejected while building — this server filters client-created parts.")
				return
			end

			local batchEnd = math.min(created + config.maxPartsPerFrame, totalParts)

			while created < batchEnd do
				local part = buildRingPart(config.radius, config.height, created, totalParts)
				part.Parent = model
				created += 1
			end

			if created >= totalParts then
				build:Disconnect()
				buildConnection = nil

				model:PivotTo(CFrame.new(currentCenter()))
				rotationConnection = RunService.Heartbeat:Connect(rotateAndAttract)
				active = true
				setWallState(true, created)
				reportStatus(string.format("Wall active (%d parts). RightShift toggles.", created))

				-- Some servers delete the wall a moment after we build it;
				-- verify it survived so we can report that instead of
				-- silently spinning a dead wall.
				task.delay(2, function()
					if active and findWallModel() == nil then
						handleWallRemoved()
					end
				end)
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
		setWallState(false, 0)

		if config.autoClearCacheOnDisable then
			local model = findWallModel()
			if model ~= nil then
				model:Destroy()
			end
		end
	end

	local function teardown()
		if destroyed then
			return
		end

		stop()
		destroyed = true

		local model = findWallModel()
		if model ~= nil then
			model:Destroy()
		end

		for _, connection in connections do
			connection:Disconnect()
		end

		if statusPanelAPI ~= nil then
			statusPanelAPI.destroy()
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

-- A small status panel in the corner of the screen. It is deliberately
-- minimal: its job is to show what the script is doing and why it might
-- not be working, not to clone a full script hub.
local function createStatusPanel(): StatusPanel
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("LastToLeaveBoxPanel")
	if existing ~= nil then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LastToLeaveBoxPanel"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Size = UDim2.fromOffset(280, 150)
	frame.Position = UDim2.new(1, -12, 1, -12)
	frame.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(0, 10)
	frameCorner.Parent = frame

	local frameStroke = Instance.new("UIStroke")
	frameStroke.Color = Color3.fromRGB(70, 80, 100)
	frameStroke.Thickness = 1
	frameStroke.Parent = frame

	local titleBar = Instance.new("TextLabel")
	titleBar.Size = UDim2.new(1, 0, 0, 30)
	titleBar.BackgroundColor3 = Color3.fromRGB(34, 37, 48)
	titleBar.Text = "Last to Leave Box"
	titleBar.TextColor3 = Color3.fromRGB(235, 235, 235)
	titleBar.Font = Enum.Font.SourceSansBold
	titleBar.TextSize = 16
	titleBar.Parent = frame

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, -20, 0, 56)
	statusLabel.Position = UDim2.fromOffset(10, 36)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "Starting..."
	statusLabel.TextColor3 = Color3.fromRGB(200, 205, 215)
	statusLabel.Font = Enum.Font.SourceSans
	statusLabel.TextSize = 13
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.TextWrapped = true
	statusLabel.Parent = frame

	local toggleButton = Instance.new("TextButton")
	toggleButton.Size = UDim2.fromOffset(120, 30)
	toggleButton.Position = UDim2.fromOffset(10, 104)
	toggleButton.BackgroundColor3 = Color3.fromRGB(45, 120, 255)
	toggleButton.Text = "Enable"
	toggleButton.TextColor3 = Color3.new(1, 1, 1)
	toggleButton.Font = Enum.Font.SourceSansBold
	toggleButton.TextSize = 14
	toggleButton.BorderSizePixel = 0
	toggleButton.Parent = frame

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 6)
	toggleCorner.Parent = toggleButton

	local removeButton = Instance.new("TextButton")
	removeButton.Size = UDim2.fromOffset(120, 30)
	removeButton.Position = UDim2.fromOffset(150, 104)
	removeButton.BackgroundColor3 = Color3.fromRGB(190, 60, 60)
	removeButton.Text = "Remove"
	removeButton.TextColor3 = Color3.new(1, 1, 1)
	removeButton.Font = Enum.Font.SourceSansBold
	removeButton.TextSize = 14
	removeButton.BorderSizePixel = 0
	removeButton.Parent = frame

	local removeCorner = Instance.new("UICorner")
	removeCorner.CornerRadius = UDim.new(0, 6)
	removeCorner.Parent = removeButton

	local panelConnections: { RBXScriptConnection } = {}
	local lastMessage = ""
	local lastRefresh = 0

	local function setStatus(text: string)
		lastMessage = text
		statusLabel.Text = text
	end

	local function destroy()
		for _, connection in panelConnections do
			connection:Disconnect()
		end

		screenGui:Destroy()
	end

	-- Drag the panel by its title bar.
	local dragging = false
	local dragStart = Vector2.zero
	local frameStart = frame.Position

	table.insert(panelConnections, titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			frameStart = frame.Position
		end
	end))

	table.insert(panelConnections, UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			frame.Position = UDim2.fromOffset(frameStart.X.Offset + delta.X, frameStart.Y.Offset + delta.Y)
		end
	end))

	table.insert(panelConnections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	toggleButton.MouseButton1Click:Connect(function()
		if boundAPI ~= nil then
			boundAPI.toggle()
		end
	end)

	removeButton.MouseButton1Click:Connect(function()
		if boundAPI ~= nil then
			boundAPI.destroy()
		end
	end)

	-- Refresh the state line a few times per second.
	table.insert(panelConnections, RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastRefresh < 0.25 then
			return
		end
		lastRefresh = now

		local stateText = if wallState.active then string.format("Active — %d parts", wallState.partCount) else "Disabled"
		statusLabel.Text = stateText .. "\n" .. lastMessage
		toggleButton.Text = if wallState.active then "Disable" else "Enable"
	end))

	return {
		setStatus = setStatus,
		destroy = destroy,
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
	if model:IsA("Model") and model.Name == WALL_MODEL_NAME then
		model:Destroy()
	end
end

local config = resolveConfig()

local statusPanel = createStatusPanel()
statusPanelAPI = statusPanel

local wallAPI = createWall(config)
boundAPI = wallAPI
getgenv().lastToLeaveBox = wallAPI

reportStatus(string.format("Loaded on place %d — config.enabled = %s", game.PlaceId, tostring(config.enabled)))

if config.enabled then
	local ok, err = pcall(wallAPI.enable)
	if not ok then
		reportStatus("Failed to start the wall: " .. tostring(err))
	end
else
	reportStatus("Disabled by config — press RightShift or the Enable button to start.")
end
