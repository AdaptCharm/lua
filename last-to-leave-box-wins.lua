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
	enabled = false,
	debugUrl = "https://ghost-vast-stag.ngrok-free.app/api/debug",
}

-- Shared state for the panel and the bot.
local wallState = {
	botOn = false,
	message = "watching for a challenge.",
	lastRawTexts = "",
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

-- ---------- Challenge-text filter ----------
-- The lobby/HUD shows a lot of persistent text that is never a challenge
-- announcement: shop labels, role menus, money amounts, buttons. Calibrated
-- from real game payloads. Texts matching these are dropped before phase
-- detection so "Cash shop" can't trigger the cash challenge, etc.
local HUD_NOISE = {
	"cash shop", "robux shop", "shop", "swap", "unpair", "current role",
	"role change request", "like reward", "like the game", "join the group",
	"become", "choose next task", "buy", "magnet", "click button", "claim",
	"reward", "host", "guard", "task", "role",
}

local function isHudNoise(text)
	if text == nil then
		return true
	end
	local tl = lower(text)
	if tl == "" then
		return true
	end
	if tl == "yes" or tl == "no" or tl == "x" or tl == "~" or tl == "..." or tl == "." then
		return true
	end
	-- Pure numbers / money amounts: "50,000", "161K", "1.16M", "149", "437K"
	local stripped = tl:gsub("[%d%,%.%s]", ""):gsub("[km]$", "")
	if stripped == "" then
		return true
	end
	for _, word in ipairs(HUD_NOISE) do
		if string.find(tl, word, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- Keep only texts that could be a challenge announcement.
local function filterChallengeTexts(texts)
	local out = {}
	for _, t in ipairs(texts) do
		if not isHudNoise(t) then
			out[#out + 1] = t
		end
	end
	return out
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
	payload.candidates = {}
	local cands = filterChallengeTexts(texts)
	for i = 1, math.min(#cands, 12) do
		payload.candidates[i] = string.sub(cands[i], 1, 200)
	end
	payload.workspaceChildren = snapshot.workspaceChildren or {}
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
	payload.buttons = catTable(snapshot.buttons)
	payload.vivid = catTable(snapshot.vivid, 20)
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
	local seen = {}

	local function addText(t)
		if t == nil or t == "" then
			return
		end
		t = tostring(t)
		if seen[t] then
			return
		end
		seen[t] = true
		if #texts < 40 then
			texts[#texts + 1] = t
		end
	end

	local function walk(inst)
		-- Never read text from our own panel - the status line contains phase
		-- keywords that would otherwise keep the bot stuck in a wrong phase.
		if inst.Name == "LastToLeaveBoxPanel" then
			return
		end

		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			addText(inst.Text)
		end

		for _, child in ipairs(inst:GetChildren()) do
			walk(child)
		end
	end

	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if playerGui ~= nil then
		walk(playerGui)
	end

	-- Challenge announcements often float above the arena in a BillboardGui
	-- or SurfaceGui instead of PlayerGui - scan Workspace for those too.
	local visited = 0
	local function walkWorkspace(inst)
		visited = visited + 1
		if visited > 3000 then
			return -- keep the per-tick scan cheap on mobile
		end
		if inst.Name == "L2LB_FlyPad" then
			return
		end
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			-- Only collect text that lives under a GuiObject so random part
			-- names or world props can't pollute the detection.
			local p = inst.Parent
			while p ~= nil do
				if p:IsA("BillboardGui") or p:IsA("SurfaceGui") then
					addText(inst.Text)
					break
				end
				p = p.Parent
			end
		end
		for _, child in ipairs(inst:GetChildren()) do
			walkWorkspace(child)
		end
	end

	pcall(function() walkWorkspace(Workspace) end)

	return texts
end

-- Is this part inside a player/NPC character model? Their body parts look
-- like generic pickups to name matching, so they are never challenge
-- objects (this killed a "balls = other players' limbs" false positive).
local function isPartOfCharacter(obj)
	local p = obj
	while p ~= nil do
		if p:IsA("Model") and p:FindFirstChildOfClass("Humanoid") ~= nil then
			return true
		end
		p = p.Parent
	end
	return false
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
		buttons = {},
		-- Calibration: small anchored parts with vivid colours. The plate
		-- round's plates have unrecognized names, so this list reveals what a
		-- plate actually looks like for the colour-match logic.
		vivid = {},
		workspaceChildren = {},
	}

	for _, child in ipairs(Workspace:GetChildren()) do
		if #snapshot.workspaceChildren < 60 and child.Name ~= "L2LB_FlyPad" then
			snapshot.workspaceChildren[#snapshot.workspaceChildren + 1] = child.Name
		end
	end

	for _, obj in ipairs(Workspace:GetDescendants()) do
		if obj:IsA("BasePart") and not isPartOfCharacter(obj) then
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
			elseif obj:FindFirstChildOfClass("ClickDetector", true) ~= nil or obj:FindFirstChildOfClass("ProximityPrompt", true) ~= nil or isMatch(obj.Name, {"button", "press", "switch", "lever"}) or isMatch(parentName, {"button", "press", "switch", "lever"}) then
				-- Buttons go last so masks/plates/etc. with click prompts
				-- still land in their own buckets. Cap keeps the payload small.
				if #snapshot.buttons < 20 then
					table.insert(snapshot.buttons, obj)
				end
			elseif obj.Anchored == true and obj.Size ~= nil and obj.Size.X <= 6 and obj.Size.Y <= 6 and obj.Size.Z <= 6 then
				-- Small vivid anchored part: likely a plate, fuel can or prop.
				-- Captured for calibration (payload field "vivid").
				local c = obj.Color
				if c ~= nil then
					local mx = math.max(c.R, c.G, c.B)
					local mn = math.min(c.R, c.G, c.B)
					if mx - mn >= 0.35 and #snapshot.vivid < 24 then
						table.insert(snapshot.vivid, obj)
					end
				end
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
	button = "PRESS THE BUTTON",
	circle = "RUN TO THE CIRCLE",
}

local function detectPhase(snapshot, texts)
	-- Drop lobby/HUD text (shop, roles, money) before any matching so the
	-- persistent UI can never trigger a challenge on its own.
	texts = filterChallengeTexts(texts)

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
	-- "🔳 Press Button 🔳" / "Press the button quickly after: X seconds!" /
	-- " PRESS BUTTON !" - a reaction-time round; we find and click the button.
	if has("press button") or has("press the button") then
		return "button", labelFor({"press button", "press the button"})
	end
	-- "⭕ The Circle ⭕" / "Run to the circle! time left: Xs" - the arena
	-- floor drops away and everyone must stand inside the ring.
	if has("the circle") or has("run to the circle") or labelHasAll("circle", "run") then
		return "circle", labelFor({"circle"})
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
	-- The slabs round announces "The slabs shown in red will disappear" but
	-- the slab parts have unrecognized names, so match on text alone and fly
	-- up (same solution as the abyss round).
	if labelHasAll("slab", "disappear") or labelHasAll("slab", "shown") then
		return "slab", labelFor({"slab", "disappear"})
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
	-- "Stand on the plate with the desired color" (title "Colored tiles").
	-- The plate parts are not name-matchable either, so detect from the
	-- announcement text and fly up (same solution as the abyss round).
	if labelHasAll("stand", "plate") or has("colored") then
		return "plate", labelFor({"stand", "plate", "colored"})
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

-- Y of the top face of a part (guards against nil Size in odd cases).
local function partTopY(part)
	local y = part.Position.Y
	if part.Size ~= nil then
		y = y + part.Size.Y / 2
	end
	return y
end

local cycle = {
	fuel = 1,
	fuelT = 0,
	fuelStep = "grab", -- generator round: "grab" the can, then "deliver" it
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

-- The generator we should fill: the one matching our team colour when the
-- game uses Blue/Red teams, otherwise the nearest generator.
local function myGenerator(snapshot)
	local gens = snapshot.generators
	if #gens == 0 then
		return nil
	end
	local wantBlue = nil
	pcall(function()
		local tc = LocalPlayer.TeamColor
		if tc ~= nil and tc.Color ~= nil then
			local c = tc.Color
			if c.B > c.R then
				wantBlue = true
			elseif c.R > c.B then
				wantBlue = false
			end
		end
	end)
	for _, g in ipairs(gens) do
		if wantBlue == true and g.Name == "Blue" then
			return g
		end
		if wantBlue == false and g.Name == "Red" then
			return g
		end
	end
	local root = getRootPart()
	local best, bestD = nil, math.huge
	for _, g in ipairs(gens) do
		local d = 0
		if root ~= nil then
			d = (root.Position - g.Position).Magnitude
		end
		if d < bestD then
			best, bestD = g, d
		end
	end
	return best
end

-- The fuel round: grab a fuel can, carry it to our generator and press its
-- button, then repeat. The fuel can is a moving red "Mark" part that the
-- name-based fuel scan never catches, so we also scan the workspace for it
-- (it usually shows up in the floors bucket via its parent's name).
local function handleGenerator(snapshot)
	local can = nil
	local root = getRootPart()
	local bestD = math.huge
	local function consider(part)
		if part == nil then
			return
		end
		local d = 0
		if root ~= nil then
			d = (root.Position - part.Position).Magnitude
		end
		if d < bestD then
			can = part
			bestD = d
		end
	end
	for _, fu in ipairs(snapshot.fuel) do
		consider(fu)
	end
	for _, fl in ipairs(snapshot.floors) do
		if lower(fl.Name) == "mark" then
			consider(fl)
		end
	end
	pcall(function()
		for _, obj in ipairs(Workspace:GetDescendants()) do
			if obj:IsA("BasePart") and not isPartOfCharacter(obj) then
				local n = lower(obj.Name)
				if n == "mark" or isMatch(n, {"fuel", "canister", "jerry", "gasoline"}) then
					consider(obj)
				end
			end
		end
	end)

	if can == nil then
		return "no fuel can found"
	end

	local now = os.clock()
	if cycle.fuelT == 0 then
		cycle.fuelT = now
	end
	if cycle.fuelStep == "grab" then
		if now - cycle.fuelT >= 1.0 then
			-- Picked it up (or at least tried): head to the generator.
			cycle.fuelStep = "deliver"
			cycle.fuelT = now
		else
			-- Keep the character overlapping the can so the pickup fires.
			teleportTo(can.Position + Vector3.new(0, 2, 0))
			return "grabbing the fuel can"
		end
	end

	-- deliver: stand on the generator and press its button.
	local gen = myGenerator(snapshot)
	if gen == nil then
		cycle.fuelStep = "grab"
		cycle.fuelT = now
		return "no generator found"
	end
	if now - cycle.fuelT >= 1.5 then
		cycle.fuelStep = "grab"
		cycle.fuelT = now
	end
	local genTop = partTopY(gen)
	teleportTo(Vector3.new(gen.Position.X, genTop + 3, gen.Position.Z))
	pcall(function()
		for _, child in ipairs(gen:GetDescendants()) do
			if child:IsA("ClickDetector") then
				child:MouseClick(LocalPlayer)
			elseif child:IsA("ProximityPrompt") then
				if ProximityPromptService ~= nil then
					ProximityPromptService:PromptButtonHoldBegan(child, LocalPlayer)
				end
			end
		end
	end)
	return "filling the generator"
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

local function handleButton(snapshot)
	local buttons = snapshot.buttons
	if #buttons > 0 then
		local root = getRootPart()
		-- Prefer parts actually named like a button: the bucket also contains
		-- pedestal/shop parts that merely carry a ClickDetector, and the real
		-- round button ("BUTTON PRESS") must win over those.
		local named = {}
		for _, b in ipairs(buttons) do
			if isMatch(b.Name, {"button", "press", "switch", "lever"}) then
				named[#named + 1] = b
			end
		end
		if #named > 0 then
			buttons = named
		end

		local best = nil
		local bestD = math.huge
		for _, b in ipairs(buttons) do
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
			-- Stand ON the pad (feet at its top) instead of 3 studs above it:
			-- with collision restored the character then lands on the pad and
			-- stays in contact instead of falling through and dying.
			local standY = partTopY(best)
			teleportTo(Vector3.new(best.Position.X, standY + 3, best.Position.Z))
			-- Try to actually press it: ClickDetector and ProximityPrompt
			-- buttons can both be triggered client-side.
			local pressed = false
			pcall(function()
				for _, child in ipairs(best:GetDescendants()) do
					if child:IsA("ClickDetector") then
						child:MouseClick(LocalPlayer)
						pressed = true
					elseif child:IsA("ProximityPrompt") then
						if ProximityPromptService ~= nil then
							ProximityPromptService:PromptButtonHoldBegan(child, LocalPlayer)
							pressed = true
						end
					end
				end
			end)
			if pressed then
				return "pressing the button"
			end
			return "standing on the button pad"
		end
	end
	-- No button found: hover out of reach (also dodges drone grabs).
	return flyUp()
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

	-- Prefer the actual Seat parts (in this game a "chair" is a model of
	-- legs/back/seat parts); only fall back to the whole bucket.
	local seats = {}
	for _, c in ipairs(chairs) do
		if c:IsA("Seat") or c:IsA("VehicleSeat") then
			seats[#seats + 1] = c
		end
	end
	if #seats > 0 then
		chairs = seats
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

-- Announcement text: 'Stand on the plate with the desired
-- <font color="rgb(127,255,0)">color</font> time left: 10s' - the wanted
-- colour is inside the rgb() in the label. Returns r,g,b in 0..1.
local function parseTargetColor()
	local texts = collectUIText()
	for _, t in ipairs(texts) do
		local r, g, b = string.match(t, "rgb%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)")
		if r ~= nil then
			return tonumber(r) / 255, tonumber(g) / 255, tonumber(b) / 255
		end
	end
	return nil
end

local function handlePlate(snapshot)
	local tr, tg, tb = parseTargetColor()
	if tr == nil then
		-- No announcement yet (or it just faded): keep the old fly-up
		-- behaviour so we don't fall through the map.
		return flyUp()
	end

	-- Scan every BasePart for the target colour. The plates have generic
	-- names, so the name-based buckets never see them - only a colour scan
	-- of the whole workspace finds them.
	local root = getRootPart()
	local best, bestD = nil, math.huge
	pcall(function()
		for _, obj in ipairs(Workspace:GetDescendants()) do
			if obj:IsA("BasePart") and not isPartOfCharacter(obj) then
				local c = obj.Color
				local s = obj.Size
				local big = s ~= nil and (s.X > 8 or s.Y > 8 or s.Z > 8)
				-- Skip big map geometry (floors, walls, red corner blocks).
				if c ~= nil and not big
					and math.abs(c.R - tr) <= 0.2 and math.abs(c.G - tg) <= 0.2 and math.abs(c.B - tb) <= 0.2 then
					local d = 0
					if root ~= nil then
						d = (root.Position - obj.Position).Magnitude
					end
					if d < bestD then
						best = obj
						bestD = d
					end
				end
			end
		end
	end)
	if best == nil then
		return flyUp() .. " (no matching plate)"
	end
	local topY = partTopY(best)
	teleportTo(Vector3.new(best.Position.X, topY + 3, best.Position.Z))
	return "standing on the rgb(" .. math.floor(tr * 255 + 0.5) .. ","
		.. math.floor(tg * 255 + 0.5) .. "," .. math.floor(tb * 255 + 0.5) .. ") plate"
end

-- "Run to the circle!": the arena floor drops away and everyone must stand
-- inside the big red ring ("Hollow Circle / Ring") in the middle.
local function handleCircle(snapshot)
	local ring = nil
	for _, fl in ipairs(snapshot.floors) do
		if fl.Name == "Hollow Circle / Ring" or isMatch(fl.Name, {"circle", "ring"}) then
			ring = fl
			break
		end
	end
	if ring == nil then
		pcall(function()
			for _, obj in ipairs(Workspace:GetDescendants()) do
				if obj:IsA("BasePart") and (obj.Name == "Hollow Circle / Ring" or isMatch(obj.Name, {"circle", "ring"})) then
					ring = obj
					break
				end
			end
		end)
	end
	if ring == nil then
		return flyUp()
	end
	-- Stand in the middle of the ring - that's the safe zone.
	local topY = partTopY(ring)
	teleportTo(Vector3.new(ring.Position.X, topY + 3, ring.Position.Z))
	return "inside the circle"
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
	slab = flyUp,
	plate = handlePlate,
	button = handleButton,
	bomb = handleBomb,
	cash = handleCash,
	above = handleAbove,
	mask = handleMask,
	ball = handleBall,
	potato = handlePotato,
	chair = handleChair,
	circle = handleCircle,
}

local FLY_PHASES = {
	laser = true,
	lava = true,
	abyss = true,
	hide = true,
	tiles = true,
	floor = true,
	slab = true,
	plate = true,
	button = true,
	circle = true,
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
			if phase == "generator" then cycle.fuel = 1 cycle.fuelT = os.clock() cycle.fuelStep = "grab" end
			if phase == "chair" then cycle.chair = 1 cycle.chairT = 0 end
			sendDebug(snapshot, texts, phase, "", "phase-change")
		end
		lastPhaseName = phase

		if phase == "chair" then
			message = handleChair(snapshot)
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
			"balls:", #snapshot.balls, "potatoes:", #snapshot.potatoes, "generators:", #snapshot.generators,
			"buttons:", #snapshot.buttons)

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
		dumpList("button", snapshot.buttons)

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
		if #texts > 0 then
			wallState.lastRawTexts = "UI texts (" .. #texts .. "): " .. table.concat(texts, " | ")
		else
			wallState.lastRawTexts = "UI texts (0): none found"
		end
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
	-- Only while the bot is ON - with the bot off it would make the character
	-- fall through the floor (CanCollide=false on the root part = noclip).
	-- During the jump round we RESTORE collision: a noclip character is never
	-- grounded, so humanoid.Jump silently does nothing (that's why the jump
	-- round "didn't work"). Keep the character collidable so it lands and
	-- can re-jump every tick.
	table.insert(connections, RunService.Stepped:Connect(function()
		if not botOn then
			return
		end

		local character = LocalPlayer.Character
		if character == nil then
			return
		end

		-- Rounds where the character must stay grounded restore collision:
		-- jump (needs to land to re-jump), chair (sit without falling through
		-- the floor), button (stand on the pad so the press registers),
		-- plate (stand on the coloured plate), circle (stand inside the ring)
		-- and generator (grab the fuel can / stand on the generator). In all
		-- of these a noclip character falls straight through the floor.
		local grounded = (lastPhaseName == "jump" or lastPhaseName == "chair"
			or lastPhaseName == "button" or lastPhaseName == "plate"
			or lastPhaseName == "circle" or lastPhaseName == "generator")
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = grounded
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
			if #texts > 0 then
				wallState.lastRawTexts = "UI texts (" .. #texts .. "): " .. table.concat(texts, " | ")
			else
				wallState.lastRawTexts = "UI texts (0): none found"
			end
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
	frame.Size = UDim2.fromOffset(320, 200)
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
	botButton.Text = "Bot: " .. (wallState.botOn and "ON" or "OFF")
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

	-- Raw texts from the last scan/auto, so the user can screenshot and share.
	local rawTextsLabel = Instance.new("TextLabel")
	rawTextsLabel.Name = "RawTextsLabel"
	rawTextsLabel.Size = UDim2.new(1, -20, 0, 52)
	rawTextsLabel.Position = UDim2.fromOffset(10, 140)
	rawTextsLabel.BackgroundTransparency = 1
	rawTextsLabel.Text = ""
	rawTextsLabel.TextColor3 = Color3.fromRGB(220, 230, 240)
	rawTextsLabel.Font = Enum.Font.SourceSans
	rawTextsLabel.TextSize = 12
	rawTextsLabel.TextXAlignment = Enum.TextXAlignment.Left
	rawTextsLabel.TextYAlignment = Enum.TextYAlignment.Top
	rawTextsLabel.TextWrapped = true
	rawTextsLabel.Parent = frame

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
		if rawTextsLabel.Text ~= wallState.lastRawTexts then
			rawTextsLabel.Text = wallState.lastRawTexts
		end
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
