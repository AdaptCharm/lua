--[[
	"Last to leave the box" - challenge auto-bot (v5)

	Client physics forces can't push other players (they are simulated on
	their clients and rejected), so this bot wins each challenge for YOU
	using primitives that work client-side:
		- teleport: move your own character via HumanoidRootPart.CFrame
		- anchor:   set parts to anchored (best effort)
		- fly pad:  client-created anchored transparent part to stand on

	Challenges handled (detected from UI text + object names):
		jump    - keep the character jumping
		laser   - fly above the laser
		lava    - fly above the lava
		abyss   - fly high so you can't fall in
		generator - touch the fuel cans (and the generator)
		slab    - anchor the red slabs, stand on a safe one
		hide    - fly high
		tiles   - fly high so you can't fall through
		bomb    - teleport to every bomb and hold the defuse button
		cash    - teleport to every cash pickup
		above   - teleport above the highest other player
		mask    - teleport onto the gas mask
		ball    - chase the falling balls
		potato  - stand next to the nearest player (best effort)
		plate   - read the announced color, stand on the matching plate
		chair   - sit on a chair; once seated, stop moving (no loop)
		floor   - fly high (falling-floor challenge)

	Debug relay: auto-posts a JSON snapshot every ~4s (config.debugUrl,
	set to false to disable), plus on Scan and on every phase change, to
	https://ghost-vast-stag.ngrok-free.app/api/debug - the ngrok tunnel
	forwards to the local debug_server.py on port 8123. Successful POSTs
	are confirmed ("posted" marker); failures show up on the status line.
	Every payload is also appended to last-to-leave-box-debug.jsonl in the
	executor workspace (appendfile/writefile) as a no-network fallback.

	Buttons: [Scan] dumps game state + posts to the debug server, [Bot]
	toggles, [Remove] tears down. RightShift toggles the bot.
]]

print("[LastToLeaveBox] loaded (challenge bot v5)")

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
	debugUrl = "https://ghost-vast-stag.ngrok-free.app/api/debug",
}

-- Shared state for the panel and the bot.
local wallState = {
	botOn = false,
	message = "watching for a challenge.",
}

-- Teardown hooks registered by subsystems (auto collector) so [Remove]
-- stops everything, not just the bot.
local extraCleanup = {}

local statusPanelAPI = nil
local boundAPI = nil

local function reportStatus(text)
	warn("[LastToLeaveBox]", text)
end

-- Show a transient status message (scan confirmation / debug errors) for a
-- few seconds; botTick defers its own message while the flash is active.
local function flashMessage(text)
	wallState.message = text
	wallState.scanFlashUntil = os.clock() + 3
end

-- ---------- Config ----------

local function resolveBoolean(value, fallback)
	if type(value) ~= "boolean" then
		return fallback
	end
	return value
end

local function resolveConfig()
	local userConfig = getEnvironment().config
	local debugUrl = DEFAULT_CONFIG.debugUrl
	if userConfig ~= nil and userConfig.debugUrl ~= nil and userConfig.debugUrl ~= false then
		debugUrl = userConfig.debugUrl
	end
	return {
		enabled = resolveBoolean(userConfig and userConfig.enabled, DEFAULT_CONFIG.enabled),
		debugUrl = debugUrl,
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

-- ---------- JSON encoder (plain Lua 5.1) ----------

local function jsonEscape(s)
	s = string.gsub(s, "\\", "\\\\")
	s = string.gsub(s, '"', '\\"')
	s = string.gsub(s, "\n", "\\n")
	s = string.gsub(s, "\r", "\\r")
	s = string.gsub(s, "\t", "\\t")
	return s
end

local function jsonEncode(v)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		if v then return "true" end
		return "false"
	elseif t == "number" then
		if v ~= v then return "null" end
		if v == math.huge or v == -math.huge then return "null" end
		if v % 1 == 0 and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return string.format("%.3f", v)
	elseif t == "string" then
		return '"' .. jsonEscape(v) .. '"'
	elseif t == "table" then
		local isArray = true
		for k in pairs(v) do
			if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
				isArray = false
				break
			end
		end
		if isArray then
			local parts = {}
			for i = 1, #v do
				parts[i] = jsonEncode(v[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			table.insert(parts, jsonEncode(tostring(k)) .. ":" .. jsonEncode(val))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return '"' .. jsonEscape(tostring(v)) .. '"'
end

-- ---------- Debug relay ----------

local function posTable(v)
	if v == nil then
		return nil
	end
	return {
		x = tonumber(string.format("%.1f", v.X)),
		y = tonumber(string.format("%.1f", v.Y)),
		z = tonumber(string.format("%.1f", v.Z)),
	}
end

local function objTable(part)
	local t = {
		name = part.Name,
		class = part.ClassName,
	}
	local p = part.Position
	if p ~= nil then
		t.pos = posTable(p)
	end
	local s = part.Size
	if s ~= nil then
		t.size = posTable(s)
	end
	local c = part.Color
	if c ~= nil then
		t.color = {
			r = tonumber(string.format("%.2f", c.R)),
			g = tonumber(string.format("%.2f", c.G)),
			b = tonumber(string.format("%.2f", c.B)),
		}
	end
	if part.Anchored ~= nil then
		t.anchored = part.Anchored
	end
	return t
end

local function catTable(list, max)
	local out = {}
	local n = math.min(#list, max or 40)
	for i = 1, n do
		out[i] = objTable(list[i])
	end
	return out
end

local function buildPayload(snapshot, texts, phase, message, reason)
	local root = getRootPart()
	local payload = {
		t = os.time(),
		reason = reason,
		placeId = tostring(game.PlaceId),
		botOn = wallState.botOn,
		phase = phase,
		message = message,
		ui = {},
		root = nil,
	}
	if root ~= nil then
		payload.root = posTable(root.Position)
	end
	local n = math.min(#texts, 12)
	for i = 1, n do
		payload.ui[i] = string.sub(texts[i], 1, 200)
	end
	payload.masks = catTable(snapshot.masks)
	payload.chairs = catTable(snapshot.chairs)
	payload.bombs = catTable(snapshot.bombs)
	payload.plates = catTable(snapshot.plates)
	payload.floors = catTable(snapshot.floors)
	payload.fuel = catTable(snapshot.fuel)
	payload.slabs = catTable(snapshot.slabs)
	payload.cash = catTable(snapshot.cash)
	payload.balls = catTable(snapshot.balls)
	payload.potatoes = catTable(snapshot.potatoes)
	payload.generators = catTable(snapshot.generators)
	return payload
end

-- A POST only counts if the server echoes the "posted" marker (a GET or a
-- wrong-signature call returns something else, so we try the next strategy).
local function responseConfirmed(resp)
	if type(resp) == "table" then
		if resp.Body ~= nil and type(resp.Body) == "string" then
			return string.find(resp.Body, "posted", 1, true) ~= nil
		end
		return false
	end
	if type(resp) == "string" then
		return string.find(resp, "posted", 1, true) ~= nil
	end
	return false
end

-- Executors vary in which HTTP calls they hook, so try every known form
-- against every candidate URL (public tunnel first, then localhost).
local function tryHttpPost(urls, body)
	local lastErrs = {}
	for ui = 1, #urls do
		local u = urls[ui]
		local strategies = {
			function()
				return game:HttpGet(u, false, { ["Content-Type"] = "application/json" }, "POST", body)
			end,
			function()
				return game:HttpGet(u, "POST", body)
			end,
			function()
				return game:HttpPost(u, body, "application/json")
			end,
			function()
				return game:GetService("HttpService"):PostAsync(u, body, "application/json")
			end,
		}
		if request ~= nil then
			table.insert(strategies, function()
				return request({
					Url = u,
					Method = "POST",
					Headers = { ["Content-Type"] = "application/json" },
					Body = body,
				})
			end)
		end
		for i = 1, #strategies do
			local ok, resp = pcall(strategies[i])
			if ok and responseConfirmed(resp) then
				return true, nil
			end
			if ok then
				lastErrs[#lastErrs + 1] = u .. " -> method " .. i .. " unconfirmed"
			else
				lastErrs[#lastErrs + 1] = u .. " -> " .. tostring(resp)
			end
		end
	end
	return false, table.concat(lastErrs, " | ")
end

-- Local file fallback: if every HTTP route fails, keep the same payloads in
-- the executor's workspace so no data is lost.
local function logToFile(line)
	if appendfile ~= nil then
		local ok = pcall(function() appendfile("last-to-leave-box-debug.jsonl", line .. "\n") end)
		return ok
	elseif writefile ~= nil then
		local ok = pcall(function()
			local existing = ""
			if readfile ~= nil then
				local ok2, data = pcall(readfile, "last-to-leave-box-debug.jsonl")
				if ok2 and data ~= nil then
					existing = data
				end
			end
			writefile("last-to-leave-box-debug.jsonl", existing .. line .. "\n")
		end)
		return ok
	end
	return false
end

local function sendDebug(snapshot, texts, phase, message, reason)
	local cfg = getEnvironment().config
	local url = DEFAULT_CONFIG.debugUrl
	if cfg ~= nil and cfg.debugUrl ~= nil then
		if cfg.debugUrl == false then
			return
		end
		url = cfg.debugUrl
	end

	local urls = { url }
	if url ~= "http://127.0.0.1:8123/api/debug" then
		urls[#urls + 1] = "http://127.0.0.1:8123/api/debug"
	end

	local payload = buildPayload(snapshot, texts, phase, message, reason)
	local body = jsonEncode(payload)

	local function post()
		local ok, err = tryHttpPost(urls, body)
		local fileOk = logToFile(body)
		if ok then
			if reason == "scan" then
				flashMessage("Scan sent - posted to the debug server")
			end
			return
		end
		if fileOk then
			warn("[LastToLeaveBox] debug send failed, saved to file:", tostring(err))
			if reason == "scan" or reason == "phase-change" then
				flashMessage("HTTP blocked - saved to file")
			end
		else
			warn("[LastToLeaveBox] debug send failed:", tostring(err))
			if reason == "scan" or reason == "phase-change" then
				flashMessage("debug POST failed: " .. string.sub(tostring(err), 1, 120))
			end
		end
	end

	local ok2, err2 = pcall(delay, 0, post)
	if not ok2 then
		warn("[LastToLeaveBox] debug send error:", tostring(err2))
		wallState.message = "debug send error: " .. string.sub(tostring(err2), 1, 120)
	end
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

-- Best-matching color NAME for a plate's RGB, using hue so off-shade plate
-- colors ("red" plates that are actually dark red / orange-red) still match
-- "red". RGB-distance matching fails here (a dark red is closer to brown).
local function classifyColor(c)
	local max = math.max(c.R, c.G, c.B)
	local min = math.min(c.R, c.G, c.B)
	local d = max - min
	local value = max

	-- No dominant hue: white or black.
	if d < 0.15 then
		if value > 0.5 then
			return "white"
		end
		return "black"
	end

	-- Hue in degrees 0..360.
	local h = 0
	if max == c.R then
		h = ((c.G - c.B) / d) % 6
	elseif max == c.G then
		h = (c.B - c.R) / d + 2
	else
		h = (c.R - c.G) / d + 4
	end
	h = h * 60

	local hueNames = {
		{ "red", 0 },
		{ "orange", 30 },
		{ "yellow", 60 },
		{ "lime", 90 },
		{ "green", 120 },
		{ "cyan", 180 },
		{ "blue", 240 },
		{ "purple", 275 },
		{ "magenta", 300 },
		{ "pink", 330 },
		{ "red", 360 },
	}
	local best = "red"
	local bestD = math.huge
	for _, e in ipairs(hueNames) do
		local dd = math.abs(h - e[2])
		if dd > 180 then
			dd = 360 - dd
		end
		if dd < bestD then
			best = e[1]
			bestD = dd
		end
	end
	-- Dark reds/oranges read as brown.
	if (best == "red" or best == "orange") and value < 0.45 then
		return "brown"
	end
	return best
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
		-- keywords that would otherwise keep the bot stuck in a wrong phase.
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
		fuel = {},
		slabs = {},
		cash = {},
		balls = {},
		potatoes = {},
		generators = {},
	}

	for _, obj in ipairs(Workspace:GetDescendants()) do
		if obj:IsA("BasePart") then
			local parentName = ""
			if obj.Parent ~= nil then
				parentName = obj.Parent.Name
			end

			if isMatch(obj.Name, {"mask", "gas"}) or isMatch(parentName, {"mask", "gas"}) then
				table.insert(snapshot.masks, obj)
			elseif isMatch(obj.Name, {"fuel", "canister", "jerry", "gasoline"}) or isMatch(parentName, {"fuel", "canister", "jerry", "gasoline"}) then
				table.insert(snapshot.fuel, obj)
			elseif isMatch(obj.Name, {"generator"}) or isMatch(parentName, {"generator"}) then
				table.insert(snapshot.generators, obj)
			elseif isMatch(obj.Name, {"slab"}) or isMatch(parentName, {"slab"}) then
				table.insert(snapshot.slabs, obj)
			elseif isMatch(obj.Name, {"cash", "money", "dollar", "coin"}) or isMatch(parentName, {"cash", "money", "dollar", "coin"}) then
				table.insert(snapshot.cash, obj)
			elseif isMatch(obj.Name, {"ball"}) or isMatch(parentName, {"ball"}) then
				table.insert(snapshot.balls, obj)
			elseif isMatch(obj.Name, {"potato"}) or isMatch(parentName, {"potato"}) then
				table.insert(snapshot.potatoes, obj)
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

local CHALLENGE_NAMES = {
	jump = "JUMP TO AVOID DAMAGE",
	laser = "DON'T TOUCH THE LASER",
	lava = "DON'T DROWN IN THE LAVA",
	abyss = "DON'T FALL INTO THE ABYSS",
	generator = "FILL THE GENERATOR WITH FUEL",
	slab = "RED SLABS WILL DISAPPEAR",
	hide = "HIDE",
	tiles = "TILES ARE DISAPPEARING",
	bomb = "DEFUSE THE BOMBS",
	cash = "COLLECT CASH",
	above = "BE ABOVE ALL",
	mask = "PICK UP THE GAS MASK",
	ball = "CATCH THE BALL",
	potato = "THE POTATO WILL EXPLODE",
	plate = "STAND ON THE RIGHT COLOR",
	chair = "SIT DOWN",
	floor = "DON'T FALL",
}

local function detectPhase(snapshot, texts)
	local combined = lower(table.concat(texts, " "))

	local function has(keyword)
		return string.find(combined, keyword, 1, true) ~= nil
	end

	-- A hazard challenge (fly-up) only counts when ONE label pairs the
	-- hazard word with an action word, so a lobby/menu mention of "lava",
	-- "laser", "abyss" or "tiles" can't trigger a lethal fly-up.
	local function hazardMatch(hazard, actions)
		for _, t in ipairs(texts) do
			local tl = lower(t)
			if string.find(tl, hazard, 1, true) ~= nil then
				for _, act in ipairs(actions) do
					if string.find(tl, act, 1, true) ~= nil then
						return true
					end
				end
			end
		end
		return false
	end

	-- Like hazardMatch but requires ALL keywords in a single label, so a
	-- lobby/menu mention of one word alone (e.g. "HOT POTATO" preview) won't
	-- match unless the real announcement also includes "explode" or "pass".
	local function labelHasAll(...)
		local keywords = { ... }
		for _, t in ipairs(texts) do
			local tl = lower(t)
			local all = true
			for _, kw in ipairs(keywords) do
				if string.find(tl, kw, 1, true) == nil then
					all = false
					break
				end
			end
			if all then
				return true
			end
		end
		return false
	end

	-- The first UI label containing any of these keywords is the challenge
	-- announcement - that's what we show in the GUI.
	local function labelFor(keywords)
		for _, t in ipairs(texts) do
			local tl = lower(t)
			for _, kw in ipairs(keywords) do
				if string.find(tl, kw, 1, true) ~= nil then
					return t
				end
			end
		end
		return nil
	end

	-- Order matters: check the most specific phrases first.
	if labelHasAll("fuel", "generator") then
		return "generator", labelFor({"fuel", "generator"})
	end
	if hazardMatch("laser", {"touch", "avoid", "don't", "dont", "survive", "beam"}) then
		return "laser", labelFor({"laser"})
	end
	if hazardMatch("lava", {"drown", "don't", "dont", "avoid", "touch", "survive", "rising", "stay"}) then
		return "lava", labelFor({"lava", "drown"})
	end
	if hazardMatch("abyss", {"fall", "don't", "dont", "into", "avoid"}) then
		return "abyss", labelFor({"abyss"})
	end
	if #snapshot.slabs > 0 and has("slab") then
		return "slab", labelFor({"slab"})
	end
	if labelHasAll("potato", "explode") or labelHasAll("potato", "pass") then
		return "potato", labelFor({"potato"})
	end
	if #snapshot.cash > 0 and (has("cash") or has("money") or has("dollar")) then
		return "cash", labelFor({"cash", "money", "dollar"})
	end
	if #snapshot.balls > 0 and has("ball") then
		return "ball", labelFor({"ball"})
	end
	if has("above all") or has("highest") then
		return "above", labelFor({"above all", "highest"})
	end
	if has("hide") then
		return "hide", labelFor({"hide"})
	end
	if labelHasAll("jump", "avoid") or labelHasAll("jump", "damage") or labelHasAll("jump", "don't") or labelHasAll("jump", "dont") then
		return "jump", labelFor({"jump"})
	end
	if #snapshot.masks > 0 and (has("gas mask") or has("mask") or has("pick up")) then
		return "mask", labelFor({"gas mask", "mask", "pick up"})
	end
	if #snapshot.bombs > 0 and (has("bomb") or has("defuse")) then
		return "bomb", labelFor({"bomb", "defuse"})
	end
	if #snapshot.chairs > 0 and (has("sit") or has("chair")) then
		return "chair", labelFor({"sit", "chair"})
	end
	if hazardMatch("tile", {"disappear", "fall", "don't", "dont"}) or (has("disappear") and has("fall")) then
		return "tiles", labelFor({"tile", "disappear", "fall"})
	end
	if #snapshot.plates > 0 and (has("stand") or has("plate") or has("color")) then
		local entry = findColorInText(combined)
		if entry ~= nil then
			return "plate", labelFor({"stand", "plate", "color"})
		end
	end
	if #snapshot.floors > 0 and (has("floor") or has("fall")) then
		return "floor", labelFor({"floor", "fall"})
	end

	return "unknown", nil
end

-- ---------- Fly pad (client-created anchored platform) ----------

local flyPad = nil
local flyAlt = nil -- hover altitude chosen once per fly phase

local function clearFlyPad()
	if flyPad ~= nil then
		pcall(function() flyPad:Destroy() end)
		flyPad = nil
	end
	flyAlt = nil
end

local function flyUp()
	local root = getRootPart()
	if root == nil then
		return "no root"
	end

	local pos = root.Position
	if flyAlt == nil then
		flyAlt = pos.Y + 30 -- pick a fixed hover altitude once per phase
	end

	if flyPad == nil or flyPad.Parent == nil then
		local ok, pad = pcall(function()
			local p = Instance.new("Part")
			p.Name = "L2LB_FlyPad"
			p.Anchored = true
			p.CanCollide = true
			p.Transparency = 1
			p.Size = Vector3.new(12, 1, 12)
			p.Parent = Workspace
			return p
		end)
		if ok then
			flyPad = pad
		end
	end

	local target = Vector3.new(pos.X, flyAlt, pos.Z)
	if flyPad ~= nil then
		flyPad.Position = Vector3.new(target.X, target.Y - 3, target.Z)
	end
	-- Only re-teleport once we drop below the hover altitude. This keeps us
	-- hovering instead of stacking +30 studs every tick into the kill zone.
	if pos.Y < flyAlt - 5 then
		teleportTo(target)
	end
	return "hovering above the hazard"
end

-- ---------- Phase handlers ----------

local cycle = {
	fuel = 1,
	fuelT = 0,
	bomb = 1,
	bombT = 0,
	cash = 1,
	cashT = 0,
	chair = 1,
	chairT = 0,
}

local botState = {
	holdingDefuse = false,
}

local function setDefuse(on)
	if on and not botState.holdingDefuse then
		VirtualUser:Button1Down()
		botState.holdingDefuse = true
	elseif not on and botState.holdingDefuse then
		VirtualUser:Button1Up()
		botState.holdingDefuse = false
	end
end

local function handleJump()
	local humanoid = getHumanoid()
	if humanoid ~= nil then
		humanoid.Jump = true
	end
	return "jumping to avoid damage"
end

local function handleGenerator(snapshot)
	local fuel = snapshot.fuel
	if #fuel == 0 then
		return "no fuel found"
	end
	if cycle.fuel > #fuel then
		cycle.fuel = 1
	end
	if os.clock() - cycle.fuelT >= 0.5 then
		cycle.fuelT = os.clock()
		cycle.fuel = cycle.fuel + 1
		if cycle.fuel > #fuel then
			cycle.fuel = 1
		end
	end
	local item = fuel[cycle.fuel]
	teleportTo(item.Position + Vector3.new(0, 3, 0))
	local gens = snapshot.generators
	if #gens > 0 and cycle.fuel % 3 == 0 then
		teleportTo(gens[1].Position + Vector3.new(0, 3, 0))
	end
	return "fueling the generator"
end

local function handleSlab(snapshot)
	local slabs = snapshot.slabs
	if #slabs == 0 then
		return "no slabs found"
	end
	local root = getRootPart()
	local safe = nil
	local safeD = math.huge
	for _, s in ipairs(slabs) do
		pcall(function() s.Anchored = true end)
		local c = s.Color
		local isRed = false
		if c ~= nil then
			isRed = c.R > 0.4 and c.R > c.G * 1.4 and c.R > c.B * 1.4
		end
		if not isRed then
			local d = 0
			if root ~= nil then
				d = (root.Position - s.Position).Magnitude
			end
			if d < safeD then
				safe = s
				safeD = d
			end
		end
	end
	if safe ~= nil then
		teleportTo(safe.Position + Vector3.new(0, 3, 0))
		return "standing on a safe slab"
	end
	return "all slabs are red - anchoring"
end

local function handleBomb(snapshot)
	local bombs = snapshot.bombs
	if #bombs == 0 then
		return "no bombs found"
	end
	setDefuse(true)
	if cycle.bomb > #bombs then
		cycle.bomb = 1
	end
	if os.clock() - cycle.bombT >= 0.6 then
		cycle.bombT = os.clock()
		cycle.bomb = cycle.bomb + 1
		if cycle.bomb > #bombs then
			cycle.bomb = 1
		end
	end
	local item = bombs[cycle.bomb]
	teleportTo(item.Position + Vector3.new(0, 2, 0))
	return "defusing bomb " .. cycle.bomb .. "/" .. #bombs
end

local function handleCash(snapshot)
	local cash = snapshot.cash
	if #cash == 0 then
		return "no cash found"
	end
	if cycle.cash > #cash then
		cycle.cash = 1
	end
	if os.clock() - cycle.cashT >= 0.5 then
		cycle.cashT = os.clock()
		cycle.cash = cycle.cash + 1
		if cycle.cash > #cash then
			cycle.cash = 1
		end
	end
	local item = cash[cycle.cash]
	teleportTo(item.Position + Vector3.new(0, 3, 0))
	return "collecting cash " .. cycle.cash .. "/" .. #cash
end

local function handleAbove()
	local target = nil
	local bestY = -math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local char = player.Character
			if char ~= nil then
				local r = char:FindFirstChild("HumanoidRootPart")
				if r ~= nil and r:IsA("BasePart") then
					local y = r.Position.Y
					if y > bestY then
						bestY = y
						target = r.Position
					end
				end
			end
		end
	end
	if target ~= nil then
		teleportTo(target + Vector3.new(0, 5, 0))
		return "above the highest player"
	end
	return flyUp()
end

local function handleMask(snapshot)
	local mask = snapshot.masks[1]
	if mask == nil then
		return "no mask found"
	end
	teleportTo(mask.Position + Vector3.new(0, 3, 0))
	return "picking up the gas mask"
end

local function handleBall(snapshot)
	local balls = snapshot.balls
	if #balls == 0 then
		return "no balls found"
	end
	local root = getRootPart()
	local best = nil
	local bestD = math.huge
	for _, b in ipairs(balls) do
		local d = 0
		if root ~= nil then
			d = (root.Position - b.Position).Magnitude
		end
		if d < bestD then
			best = b
			bestD = d
		end
	end
	if best ~= nil then
		teleportTo(best.Position + Vector3.new(0, 3, 0))
	end
	return "chasing the ball"
end

local function handlePotato()
	local root = getRootPart()
	if root == nil then
		return "no root"
	end
	local target = nil
	local bestD = math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local char = player.Character
			if char ~= nil then
				local r = char:FindFirstChild("HumanoidRootPart")
				if r ~= nil and r:IsA("BasePart") then
					local d = (root.Position - r.Position).Magnitude
					if d < bestD then
						target = r.Position
						bestD = d
					end
				end
			end
		end
	end
	if target ~= nil then
		teleportTo(target + Vector3.new(0, 3, 0))
		return "next to the nearest player"
	end
	return "no other players found"
end

local function handlePlate(snapshot, combined)
	local entry = findColorInText(combined)
	if entry == nil then
		return "color not announced"
	end
	local wanted = entry[1]
	local root = getRootPart()
	local best = nil
	local bestD = math.huge
	for _, part in ipairs(snapshot.plates) do
		local c = part.Color
		if c ~= nil and classifyColor(c) == wanted then
			local d = 0
			if root ~= nil then
				d = (root.Position - part.Position).Magnitude
			end
			if d < bestD then
				best = part
				bestD = d
			end
		end
	end
	if best == nil then
		return "no plate matches " .. wanted
	end
	teleportTo(best.Position + Vector3.new(0, 3, 0))
	return "standing on the " .. wanted .. " plate"
end

local function handleChair(snapshot)
	local humanoid = getHumanoid()
	if humanoid ~= nil and humanoid.Sit == true then
		return "already sitting"
	end
	local chairs = snapshot.chairs
	if #chairs == 0 then
		return "no chairs found"
	end

	local now = os.clock()
	if cycle.chairT ~= 0 and now - cycle.chairT < 1.0 then
		-- We sat recently and got unseated: hold still briefly before the
		-- next hop so we never teleport-spam between chairs.
		return "waiting to switch chairs"
	end
	if cycle.chairT ~= 0 and now - cycle.chairT >= 1.0 then
		cycle.chair = cycle.chair + 1
	end
	cycle.chairT = now

	if cycle.chair > #chairs then
		cycle.chair = 1
	end
	local chair = chairs[cycle.chair]
	teleportTo(chair.Position + Vector3.new(0, 3, 0))
	if humanoid ~= nil then
		humanoid.Sit = true
	end
	return "sitting on chair " .. cycle.chair
end

local HANDLERS = {
	jump = handleJump,
	laser = flyUp,
	lava = flyUp,
	abyss = flyUp,
	hide = flyUp,
	tiles = flyUp,
	floor = flyUp,
	generator = handleGenerator,
	slab = handleSlab,
	bomb = handleBomb,
	cash = handleCash,
	above = handleAbove,
	mask = handleMask,
	ball = handleBall,
	potato = handlePotato,
	chair = handleChair,
}

local FLY_PHASES = {
	laser = true,
	lava = true,
	abyss = true,
	hide = true,
	tiles = true,
	floor = true,
}

-- ---------- Bot ----------

local function createBot(config)
	local connections = {}
	local botConnection = nil

	local botOn = config.enabled
	local lastMessage = ""
	local lastTick = 0
	local lastPhaseName = ""

	local function setBotState(on)
		botOn = on
		wallState.botOn = on
	end

	local function botTick()
		if not botOn then
			setDefuse(false)
			return
		end

		local now = os.clock()
		if now - lastTick < 0.25 then
			return
		end
		lastTick = now

		local snapshot = scanWorkspace()
		local texts = collectUIText()
		local phase, matchedLabel = detectPhase(snapshot, texts)
		local combined = lower(table.concat(texts, " "))
		local message = ""

		if phase ~= lastPhaseName then
			-- Leaving a phase: release buttons and clean up the fly pad.
			if lastPhaseName == "bomb" then
				setDefuse(false)
			end
			if FLY_PHASES[lastPhaseName] then
				clearFlyPad()
			end
			if phase == "bomb" then cycle.bomb = 1 cycle.bombT = os.clock() end
			if phase == "cash" then cycle.cash = 1 cycle.cashT = os.clock() end
			if phase == "generator" then cycle.fuel = 1 cycle.fuelT = os.clock() end
			if phase == "chair" then cycle.chair = 1 end
			sendDebug(snapshot, texts, phase, "", "phase-change")
		end
		lastPhaseName = phase

		if phase == "chair" then
			message = handleChair(snapshot)
		elseif phase == "plate" then
			message = handlePlate(snapshot, combined)
		elseif HANDLERS[phase] ~= nil then
			message = HANDLERS[phase](snapshot)
		else
			message = "watching for a challenge."
			setDefuse(false)
		end

		-- GUI: challenge name (from the announcement label) or idle text.
		local display = "watching for a challenge."
		if phase ~= "unknown" then
			display = matchedLabel
			if display == nil or display == "" then
				display = CHALLENGE_NAMES[phase] or phase
			end
		end
		if wallState.scanFlashUntil ~= nil and now < wallState.scanFlashUntil then
			-- A transient message (scan confirmation / debug error) is on
			-- screen; leave it alone until it expires.
		else
			wallState.message = display
		end

		if message ~= lastMessage then
			lastMessage = message
			reportStatus("Bot: " .. phase .. " - " .. message)
		end
	end

	-- ---------- API methods ----------

	local function enable()
		if botOn then
			return
		end
		setBotState(true)
		wallState.message = "watching for a challenge."
		reportStatus("Bot enabled")
	end

	local function disable()
		if not botOn then
			return
		end
		setBotState(false)
		setDefuse(false)
		clearFlyPad()
		wallState.message = "Bot is OFF"
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
		print("masks:", #snapshot.masks, "chairs:", #snapshot.chairs, "bombs:", #snapshot.bombs,
			"plates:", #snapshot.plates, "floors:", #snapshot.floors)
		print("fuel:", #snapshot.fuel, "slabs:", #snapshot.slabs, "cash:", #snapshot.cash,
			"balls:", #snapshot.balls, "potatoes:", #snapshot.potatoes, "generators:", #snapshot.generators)

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
		dumpList("fuel", snapshot.fuel)
		dumpList("slab", snapshot.slabs)
		dumpList("cash", snapshot.cash)
		dumpList("ball", snapshot.balls)
		dumpList("potato", snapshot.potatoes)
		dumpList("generator", snapshot.generators)

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
				root.CFrame = CFrame.new(before)
			end)
		end

		print("=== Scan end ===")
		flashMessage("Scan sent - posting to the debug server...")
		sendDebug(snapshot, texts, lastPhaseName, "", "scan")
	end

	local function teardown()
		if botConnection ~= nil then
			botConnection:Disconnect()
			botConnection = nil
		end

		disable()
		setDefuse(false)
		clearFlyPad()

		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end

		for i = 1, #extraCleanup do
			local ok, err = pcall(extraCleanup[i])
			if not ok then
				warn("[LastToLeaveBox] cleanup failed:", tostring(err))
			end
		end
		extraCleanup = {}

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

-- ---------- Auto data collector ----------
-- Posts a full snapshot to the debug server on a fixed cadence (default 4s),
-- independent of the bot being on or off, so we collect calibration data
-- across many rounds without pressing Scan. First post fires immediately.

local function createCollector(config)
	local conn = nil
	local interval = 4
	if config.autoScanInterval ~= nil and config.autoScanInterval ~= false then
		interval = config.autoScanInterval
	end
	local lastPost = -9999 -- first heartbeat posts right away

	local function tick()
		local now = os.clock()
		if now - lastPost < interval then
			return
		end
		lastPost = now
		local ok, err = pcall(function()
			local snapshot = scanWorkspace()
			local texts = collectUIText()
			local phase = detectPhase(snapshot, texts)
			sendDebug(snapshot, texts, phase, "auto", "auto")
		end)
		if not ok then
			reportStatus("auto-scan error: " .. tostring(err))
			flashMessage("auto-scan error: " .. tostring(err))
		end
	end

	conn = RunService.Heartbeat:Connect(tick)

	local function destroy()
		if conn ~= nil then
			conn:Disconnect()
			conn = nil
		end
	end

	table.insert(extraCleanup, destroy)

	return { destroy = destroy }
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
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 30)
	titleBar.BackgroundColor3 = Color3.fromRGB(34, 37, 48)
	titleBar.Text = "Last to Leave Box"
	titleBar.TextColor3 = Color3.fromRGB(235, 235, 235)
	titleBar.Font = Enum.Font.SourceSansBold
	titleBar.TextSize = 16
	titleBar.Parent = frame

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.Size = UDim2.new(1, -20, 0, 56)
	statusLabel.Position = UDim2.fromOffset(10, 36)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = wallState.message
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
	scanButton.Name = "ScanButton"
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
	botButton.Name = "BotButton"
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
	removeButton.Name = "RemoveButton"
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
	local lastRefresh = 0

	local function destroy()
		for _, connection in ipairs(panelConnections) do
			connection:Disconnect()
		end

		screenGui:Destroy()
	end

	-- The panel is fixed in place: it must stay visible until [Remove] is
	-- pressed, so there is intentionally no drag-by-title behavior (on
	-- touch devices a drag used to shove the panel off-screen).

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

		statusLabel.Text = wallState.message
	end))

	return {
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

local api = createBot(config)
boundAPI = api

local collector = createCollector(config)

local statusPanel = createStatusPanel()
if statusPanel ~= nil then
	statusPanelAPI = statusPanel
else
	warn("[LastToLeaveBox] No PlayerGui - panel skipped.")
end

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

reportStatus("Loaded on place " .. tostring(game.PlaceId) .. " - bot " .. stateText ..
	". Press Scan to inspect + post to the debug server.")

if config.enabled then
	local ok, err = pcall(api.enable)
	if not ok then
		reportStatus("Failed to start bot: " .. tostring(err))
	end
end
