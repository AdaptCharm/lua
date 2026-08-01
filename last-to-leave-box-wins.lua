print("[LastToLeaveBox] loaded (challenge bot)")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if LocalPlayer == nil then
	wait(1)
	LocalPlayer = Players.LocalPlayer
end

if LocalPlayer == nil then
	warn("[LastToLeaveBox] Could not find LocalPlayer.")
	return
end

local function getEnvironment()
	local fn = _G.getgenv
	if fn ~= nil then
		return fn()
	end
	return _G
end

local DEFAULT_CONFIG = {
	enabled = true,
}

-- Shared state for the panel.
local wallState = {
	botOn = false,
	message = "",
}

local statusPanelAPI = nil
local boundAPI = nil

local function reportStatus(text)
	if statusPanelAPI ~= nil then
		statusPanelAPI.setStatus(text)
	end

	warn("[LastToLeaveBox]", text)
end

-- ---------- Config ----------

local function resolveNumber(value, fallback)
	if type(value) ~= "number" then
		return fallback
	end
	return value
end

local function resolveBoolean(value, fallback)
	if type(value) ~= "boolean" then
		return fallback
	end
	return value
end

local function resolveConfig()
	local userConfig = getEnvironment().config
	return {
		enabled = resolveBoolean(userConfig and userConfig.enabled, DEFAULT_CONFIG.enabled),
	}
end

-- ---------- Utilities ----------

local function getRootPart()
	local character = LocalPlayer.Character
	if character == nil then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end

	return nil
end

local function getHumanoid()
	local character = LocalPlayer.Character
	if character == nil then
		return nil
	end

	return character:FindFirstChildOfClass("Humanoid")
end

local function teleportTo(position)
	local root = getRootPart()
	if root == nil then
		return false
	end

	if (root.Position - position).Magnitude < 4 then
		return true
	end

	root.CFrame = CFrame.new(position)
	return true
end

local function lower(text)
	return string.lower(text or "")
end

-- ---------- Color helpers ----------

local COLOR_MAP = {
	{ "red", Color3.fromRGB(255, 0, 0) },
	{ "blue", Color3.fromRGB(0, 0, 255) },
	{ "green", Color3.fromRGB(0, 255, 0) },
	{ "yellow", Color3.fromRGB(255, 255, 0) },
	{ "orange", Color3.fromRGB(255, 165, 0) },
	{ "purple", Color3.fromRGB(128, 0, 255) },
	{ "pink", Color3.fromRGB(255, 105, 180) },
	{ "white", Color3.fromRGB(255, 255, 255) },
	{ "black", Color3.fromRGB(0, 0, 0) },
	{ "cyan", Color3.fromRGB(0, 255, 255) },
	{ "magenta", Color3.fromRGB(255, 0, 255) },
	{ "brown", Color3.fromRGB(165, 42, 42) },
	{ "lime", Color3.fromRGB(50, 255, 50) },
}

local function findColorInText(text)
	local t = lower(text)
	for _, entry in ipairs(COLOR_MAP) do
		if string.find(t, entry[1], 1, true) ~= nil then
			return entry
		end
	end
	return nil
end

local function closestPlate(plates, targetColor)
	local best = nil
	local bestDist = math.huge

	for _, part in ipairs(plates) do
		local c = part.Color
		local d = math.abs(c.R - targetColor.R) + math.abs(c.G - targetColor.G) + math.abs(c.B - targetColor.B)
		if d < bestDist then
			best = part
			bestDist = d
		end
	end

	if best ~= nil and bestDist < 0.5 then
		return best
	end

	return nil
end

-- ---------- Object scanning ----------

local function isMatch(name, keywords)
	local n = lower(name)
	for _, kw in ipairs(keywords) do
		if string.find(n, kw, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function collectUIText()
	local texts = {}
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if playerGui == nil then
		return texts
	end

	local function walk(inst)
		-- Never read text from our own panel - the status line contains phase
		-- keywords ("walking onto the gas mask", ...) that would otherwise
		-- keep the bot stuck in the wrong phase forever.
		if inst.Name == "LastToLeaveBoxPanel" then
			return
		end

		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			local t = inst.Text
			if t ~= nil and t ~= "" then
				table.insert(texts, t)
			end
		end

		for _, child in ipairs(inst:GetChildren()) do
			walk(child)
		end
	end

	walk(playerGui)
	return texts
end

local function scanWorkspace()
	local snapshot = {
		masks = {},
		chairs = {},
		bombs = {},
		plates = {},
		floors = {},
	}

	for _, obj in ipairs(Workspace:GetDescendants()) do
		if obj:IsA("BasePart") then
			local parentName = ""
			if obj.Parent ~= nil then
				parentName = obj.Parent.Name
			end

			if isMatch(obj.Name, {"mask", "gas"}) or isMatch(parentName, {"mask", "gas"}) then
				table.insert(snapshot.masks, obj)
			elseif obj:IsA("Seat") or obj:IsA("VehicleSeat") or isMatch(obj.Name, {"chair", "seat"}) or isMatch(parentName, {"chair", "seat"}) then
				table.insert(snapshot.chairs, obj)
			elseif isMatch(obj.Name, {"bomb", "defuse"}) or isMatch(parentName, {"bomb", "defuse"}) then
				table.insert(snapshot.bombs, obj)
			elseif isMatch(obj.Name, {"plate", "pad", "panel", "tile"}) or isMatch(parentName, {"plate", "pad", "panel", "tile"}) then
				table.insert(snapshot.plates, obj)
			elseif isMatch(obj.Name, {"floor", "platform", "ground"}) or isMatch(parentName, {"floor", "platform", "ground"}) then
				table.insert(snapshot.floors, obj)
			end
		end
	end

	return snapshot
end

-- ---------- Phase detection ----------

local function detectPhase(snapshot, combined)
	local function has(keyword)
		return string.find(combined, keyword, 1, true) ~= nil
	end

	if #snapshot.masks > 0 and (has("gas mask") or has("pick up") or has("mask")) then
		return "mask"
	end

	if #snapshot.chairs > 0 and (has("sit") or has("chair")) then
		return "chair"
	end

	if #snapshot.bombs > 0 and (has("bomb") or has("defuse")) then
		return "bomb"
	end

	if #snapshot.plates > 0 and (has("stand") or has("plate") or has("color")) then
		local entry = findColorInText(combined)
		if entry ~= nil then
			return "plate"
		end
	end

	if #snapshot.floors > 0 and (has("don't fall") or has("dont fall") or has("fall") or has("floor")) then
		return "floor"
	end

	return "unknown"
end

-- ---------- Phase handlers ----------

local function handleMask(snapshot)
	local mask = snapshot.masks[1]
	if mask == nil then
		return "no mask found"
	end

	teleportTo(mask.Position + Vector3.new(0, 3, 0))
	return "walking onto the gas mask"
end

local function handleChair(snapshot)
	local chair = snapshot.chairs[1]
	if chair == nil then
		return "no chair found"
	end

	teleportTo(chair.Position + Vector3.new(0, 3, 0))

	local humanoid = getHumanoid()
	if humanoid ~= nil then
		humanoid.Sit = true
	end

	return "sitting on a chair"
end

local function floorTop(part)
	return part.Position + Vector3.new(0, part.Size.Y / 2 + 2, 0)
end

local function findHighestFloorTop(floors)
	local best = nil
	local bestY = -math.huge
	for _, part in ipairs(floors) do
		local top = floorTop(part)
		if top.Y > bestY then
			best = top
			bestY = top.Y
		end
	end
	return best
end

local function handleFloor(snapshot)
	local anchoredAny = false
	for _, part in ipairs(snapshot.floors) do
		if not part.Anchored then
			part.Anchored = true
			anchoredAny = true
		end
	end

	local root = getRootPart()
	if root ~= nil and root.Position.Y < 5 then
		local safe = findHighestFloorTop(snapshot.floors)
		if safe ~= nil then
			teleportTo(safe)
			return "rescued from the fall"
		end
	end

	if anchoredAny then
		return "floor anchored"
	end

	return "floor watching"
end

local function handleBomb(snapshot)
	local bomb = snapshot.bombs[1]
	if bomb == nil then
		return "no bomb found"
	end

	teleportTo(bomb.Position + Vector3.new(0, 2, 0))
	return "standing on the bomb, holding"
end

local function handlePlate(snapshot, combined)
	local entry = findColorInText(combined)
	if entry == nil then
		return "color not announced"
	end

	local plate = closestPlate(snapshot.plates, entry[2])
	if plate == nil then
		return "no plate matches " .. entry[1]
	end

	teleportTo(plate.Position + Vector3.new(0, 3, 0))
	return "standing on the " .. entry[1] .. " plate"
end

-- ---------- Bot creation ----------

local function createBot(config)
	local connections = {}
	local botConnection = nil

	local botOn = config.enabled
	local holdingDefuse = false
	local lastMessage = ""
	local lastTick = 0

	local function setBotState(on)
		botOn = on
		wallState.botOn = on
	end

	local function botTick()
		if not botOn then
			if holdingDefuse then
				VirtualUser:Button1Up()
				holdingDefuse = false
			end
			return
		end

		-- throttle: 0.25s between ticks
		local now = os.clock()
		if now - lastTick < 0.25 then
			return
		end
		lastTick = now

		local snapshot = scanWorkspace()
		local texts = collectUIText()
		local combined = lower(table.concat(texts, " "))
		local phase = detectPhase(snapshot, combined)
		local message = ""

		if phase == "mask" then
			message = handleMask(snapshot)
		elseif phase == "chair" then
			message = handleChair(snapshot)
		elseif phase == "bomb" then
			if not holdingDefuse then
				VirtualUser:Button1Down()
				holdingDefuse = true
			end
			message = handleBomb(snapshot)
		elseif phase == "plate" then
			message = handlePlate(snapshot, combined)
		elseif phase == "floor" then
			message = handleFloor(snapshot)
		else
			message = "watching for a challenge..."
			if holdingDefuse then
				VirtualUser:Button1Up()
				holdingDefuse = false
			end
		end

		if message ~= lastMessage then
			lastMessage = message
			wallState.message = message
			reportStatus("Bot: " .. phase .. " - " .. message)
		end
	end

	-- ---------- API methods ----------

	local function enable()
		if botOn then
			return
		end
		setBotState(true)
		reportStatus("Bot enabled")
	end

	local function disable()
		if not botOn then
			return
		end
		setBotState(false)
		if holdingDefuse then
			VirtualUser:Button1Up()
			holdingDefuse = false
		end
		reportStatus("Bot disabled")
	end

	local function toggle()
		if botOn then
			disable()
		else
			enable()
		end
	end

	local function dumpGame()
		print("=== LastToLeaveBox scan ===")
		print("PlaceId:", game.PlaceId)

		local ok, gname = pcall(function() return game.Name end)
		print("Name:", tostring(gname))

		local snapshot = scanWorkspace()
		local texts = collectUIText()
		print("Objects found:")
		print("masks:", #snapshot.masks, "chairs:", #snapshot.chairs, "bombs:", #snapshot.bombs, "plates:", #snapshot.plates, "floors:", #snapshot.floors)

		local function dumpList(kind, list)
			for _, part in ipairs(list) do
				local extra = ""
				if part:IsA("BasePart") and part.Color ~= nil then
					extra = string.format(" color=(%.3f,%.3f,%.3f)", part.Color.R, part.Color.G, part.Color.B)
				end
				print("  " .. kind .. ":", part.Name, part.ClassName, extra)
			end
		end
		dumpList("mask", snapshot.masks)
		dumpList("chair", snapshot.chairs)
		dumpList("bomb", snapshot.bombs)
		dumpList("plate", snapshot.plates)
		dumpList("floor", snapshot.floors)

		print("UI texts (" .. #texts .. "):")
		for _, t in ipairs(texts) do
			print("  ", t)
		end

		-- CFrame teleport probe
		local root = getRootPart()
		if root ~= nil then
			local before = root.Position
			root.CFrame = root.CFrame * CFrame.new(1, 0, 0)
			local probeBefore = root.Position
			delay(0.4, function()
				local probeAfter = root.Position
				local dist = (before - probeAfter).Magnitude
				print("Teleport probe: moved", string.format("%.2f", dist), "studs (works if > 0.5)")
				-- restore position
				root.CFrame = CFrame.new(before)
			end)
		end

		print("=== Scan end ===")
		reportStatus("Scan complete - see executor console")
	end

	local function teardown()
		if botConnection ~= nil then
			botConnection:Disconnect()
			botConnection = nil
		end

		disable()

		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end

		if statusPanelAPI ~= nil then
			statusPanelAPI.destroy()
		end
	end

	-- Bot tick on Heartbeat.
	botConnection = RunService.Heartbeat:Connect(botTick)

	-- Anti-idle so the player doesn't get kicked while the bot works.
	table.insert(connections, LocalPlayer.Idled:Connect(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.zero)
	end))

	-- Toggle key.
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.KeyCode == Enum.KeyCode.RightShift then
			toggle()
		end
	end))

	-- Character no-collide: let us walk through parts the bot teleports us to.
	table.insert(connections, RunService.Stepped:Connect(function()
		local character = LocalPlayer.Character
		if character == nil then
			return
		end

		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
	end))

	return {
		enable = enable,
		disable = disable,
		toggle = toggle,
		destroy = teardown,
		scan = dumpGame,
	}
end

-- ---------- Status panel ----------

local function createStatusPanel()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
	if playerGui == nil then
		return nil
	end

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
	frame.Size = UDim2.fromOffset(320, 170)
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

	local BUTTON_Y = 104
	local BUTTON_H = 30

	local scanButton = Instance.new("TextButton")
	scanButton.Size = UDim2.fromOffset(80, BUTTON_H)
	scanButton.Position = UDim2.fromOffset(10, BUTTON_Y)
	scanButton.BackgroundColor3 = Color3.fromRGB(60, 140, 160)
	scanButton.Text = "Scan"
	scanButton.TextColor3 = Color3.new(1, 1, 1)
	scanButton.Font = Enum.Font.SourceSansBold
	scanButton.TextSize = 14
	scanButton.BorderSizePixel = 0
	scanButton.Parent = frame

	local scanCorner = Instance.new("UICorner")
	scanCorner.CornerRadius = UDim.new(0, 6)
	scanCorner.Parent = scanButton

	local botButton = Instance.new("TextButton")
	botButton.Size = UDim2.fromOffset(100, BUTTON_H)
	botButton.Position = UDim2.fromOffset(100, BUTTON_Y)
	botButton.BackgroundColor3 = Color3.fromRGB(45, 120, 255)
	botButton.Text = "Bot: ON"
	botButton.TextColor3 = Color3.new(1, 1, 1)
	botButton.Font = Enum.Font.SourceSansBold
	botButton.TextSize = 14
	botButton.BorderSizePixel = 0
	botButton.Parent = frame

	local botCorner = Instance.new("UICorner")
	botCorner.CornerRadius = UDim.new(0, 6)
	botCorner.Parent = botButton

	local removeButton = Instance.new("TextButton")
	removeButton.Size = UDim2.fromOffset(100, BUTTON_H)
	removeButton.Position = UDim2.fromOffset(210, BUTTON_Y)
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

	local panelConnections = {}
	local lastMessage = ""
	local lastRefresh = 0

	local function setStatus(text)
		lastMessage = text
		statusLabel.Text = text
	end

	local function destroy()
		for _, connection in ipairs(panelConnections) do
			connection:Disconnect()
		end

		screenGui:Destroy()
	end

	-- Drag by title bar.
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

	scanButton.MouseButton1Click:Connect(function()
		if boundAPI ~= nil and boundAPI.scan ~= nil then
			boundAPI.scan()
		end
	end)

	botButton.MouseButton1Click:Connect(function()
		if boundAPI ~= nil then
			boundAPI.toggle()
		end
	end)

	removeButton.MouseButton1Click:Connect(function()
		if boundAPI ~= nil then
			boundAPI.destroy()
		end
	end)

	-- Refresh the state line and button text.
	table.insert(panelConnections, RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastRefresh < 0.25 then
			return
		end
		lastRefresh = now

		if wallState.botOn then
			botButton.Text = "Bot: ON"
			botButton.BackgroundColor3 = Color3.fromRGB(45, 120, 255)
		else
			botButton.Text = "Bot: OFF"
			botButton.BackgroundColor3 = Color3.fromRGB(100, 110, 120)
		end

		local msg = wallState.message
		if msg ~= "" then
			statusLabel.Text = msg
		end
	end))

	return {
		setStatus = setStatus,
		destroy = destroy,
	}
end

-- ---------- Main ----------

print("[LastToLeaveBox] starting up...")

local previousAPI = getEnvironment().lastToLeaveBox
if previousAPI ~= nil then
	local ok, err = pcall(previousAPI.destroy)
	if not ok then
		warn("[LastToLeaveBox] Failed to clean up:", err)
	end
end

local config = resolveConfig()

local statusPanel = createStatusPanel()
if statusPanel ~= nil then
	statusPanelAPI = statusPanel
else
	warn("[LastToLeaveBox] No PlayerGui - panel skipped.")
end

local api = createBot(config)
boundAPI = api

local ok, regErr = pcall(function()
	getEnvironment().lastToLeaveBox = api
end)
if not ok then
	warn("[LastToLeaveBox] API registration failed:", regErr)
end

local stateText = "OFF"
if config.enabled then
	stateText = "ON"
end

reportStatus("Loaded on place " .. tostring(game.PlaceId) .. " - bot " .. stateText .. ". Press Scan to inspect the game.")

if config.enabled then
	local ok, err = pcall(api.enable)
	if not ok then
		reportStatus("Failed to start bot: " .. tostring(err))
	end
end
