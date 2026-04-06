-- +======================================================+
-- |            AUTO TRACK  v5                            |
-- |  Settings . Lock Mini . Line ESP . Polished Anims    |
-- +======================================================+

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

-- Destroy old instance if re-running
local _existing = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("AutoTrackGui")
if _existing then _existing:Destroy() end

-- -----------------------------------------------------
--  CONFIG
-- -----------------------------------------------------
local REQUIRE_TOOL_EQUIPPED = true
local JUMP_HEIGHT_THRESHOLD = 3.5
local JUMP_COOLDOWN         = 0.65
local MOVETO_REFRESH        = 0.12
local HOLD_DURATION         = 2.0
local DOUBLE_JUMP_POWER     = 0.6  -- multiplier of normal JumpPower (0.5 = half height, 1.0 = full height)
local LINE_ESP_DISTANCE     = 40  -- studs radius for ESP (players within this get lines + outline)
-- (fixed internally, no longer user-configurable)

-- -----------------------------------------------------
--  STATE
-- -----------------------------------------------------
local tracking      = false
local trackConn     = nil
local lastJump      = 0
local lastMoveTime  = 0
local currentTarget = nil

local lineEspOn         = false
local lineEspLines      = {}   -- [player] = { line = Frame }
local lineEspHighlights = {}   -- [player] = Highlight (character outline)
local lineEspConn       = nil

local mainVisible  = true
local miniVisible  = false
local miniLocked   = false
local onSettings   = false
local statusGuiOn  = false

local autoBomb     = false
local autoBombConn = nil
local AUTOBOMB_COUNTDOWN = 3
local AUTOBOMB_STUDS     = 15

local doubleJumpOn    = false  -- Double Jump toggle
local doubleJumpUsed  = false  -- tracks if air jump already used this flight
local doubleJumpConn  = nil

-- -----------------------------------------------------
--  LOGIC HELPERS
-- -----------------------------------------------------

-- Tag stamped on every Highlight WE create so hasHighlight ignores them
local ESP_TAG = "__AutoTrackESP__"

-- Returns true only if a FOREIGN highlight exists on the character
-- (one we didn't create ourselves)
local function hasHighlight(char)
	if not char then return false end
	for _, v in ipairs(char:GetDescendants()) do
		if v:IsA("Highlight") and not v:GetAttribute(ESP_TAG) then
			return true
		end
	end
	return false
end

local function charHasTool(char)
	if not char then return false end
	for _, v in ipairs(char:GetChildren()) do
		if v:IsA("Tool") then return true end
	end
	return false
end

local function localHasTool()
	local char     = LocalPlayer.Character
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if char then
		for _, v in ipairs(char:GetChildren()) do
			if v:IsA("Tool") then return true end
		end
	end
	if REQUIRE_TOOL_EQUIPPED then return false end
	if backpack then
		for _, v in ipairs(backpack:GetChildren()) do
			if v:IsA("Tool") then return true end
		end
	end
	return false
end

local function getRoot()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum()
	local c = LocalPlayer.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function getBestTarget()
	local root = getRoot()
	if not root then return nil end

	local myArena = getLocalArena()
	-- If not in a game, nothing to track
	if not myArena then return nil end

	local best, bestDist = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		if p == LocalPlayer then continue end
		local char = p.Character
		if not char then continue end
		local pRoot = char:FindFirstChild("HumanoidRootPart")
		local pHum  = char:FindFirstChildOfClass("Humanoid")
		if not pRoot or not pHum or pHum.Health <= 0 then continue end
		if hasHighlight(char) then continue end
		if charHasTool(char)  then continue end
		-- Must share same ActiveArena
		if getPlayerArena(p) ~= myArena then continue end
		local d = (pRoot.Position - root.Position).Magnitude
		if d < bestDist then bestDist = d; best = p end
	end
	return best
end

-- -----------------------------------------------------
--  TRACKING LOOP
-- -----------------------------------------------------

local function startTracking()
	if trackConn then return end
	lastJump = 0; lastMoveTime = 0; currentTarget = nil
	trackConn = RunService.Heartbeat:Connect(function()
		local now = tick()
		local char = LocalPlayer.Character
		local hasBomb = char and char:FindFirstChild("Bomb") ~= nil

		-- Yield to auto bomb while we don't have the bomb yet
		if autoBomb and not hasBomb then return end

		-- Don't have bomb - stand still
		if not hasBomb then
			local h, r = getHum(), getRoot()
			if h and r then h:MoveTo(r.Position) end
			currentTarget = nil; return
		end

		-- Arena check - exact same as auto bomb uses
		local myData = LocalPlayer:FindFirstChild("Data")
		local myAV   = myData and myData:FindFirstChild("ActiveArena")
		local myArena = myAV and myAV.Value
		-- "nil" string or actual nil = not in arena
		if myArena == nil or tostring(myArena) == "nil" or tostring(myArena) == "" then
			local h, r = getHum(), getRoot()
			if h and r then h:MoveTo(r.Position) end
			currentTarget = nil; return
		end

		-- Find nearest target in same arena, no bomb, no highlight
		if now - lastMoveTime >= MOVETO_REFRESH then
			lastMoveTime  = now
			local root = getRoot()
			local best, bestDist = nil, math.huge
			for _, p in ipairs(Players:GetPlayers()) do
				if p == LocalPlayer then continue end
				local pChar = p.Character
				if not pChar then continue end
				local pRoot = pChar:FindFirstChild("HumanoidRootPart")
				local pHum  = pChar:FindFirstChildOfClass("Humanoid")
				if not pRoot or not pHum or pHum.Health <= 0 then continue end
				if hasHighlight(pChar) then continue end
				if charHasTool(pChar)  then continue end
				-- Same arena - read their value the same way
				local theirData = p:FindFirstChild("Data")
				local theirAV   = theirData and theirData:FindFirstChild("ActiveArena")
				local theirArena = theirAV and theirAV.Value
				if theirArena ~= myArena then continue end
				local d = (pRoot.Position - root.Position).Magnitude
				if d < bestDist then bestDist = d; best = p end
			end
			currentTarget = best
		end

		if not currentTarget then return end
		local root, hum = getRoot(), getHum()
		if not root or not hum or hum.Health <= 0 then return end
		local tChar = currentTarget.Character
		local tRoot = tChar and tChar:FindFirstChild("HumanoidRootPart")
		if not tRoot then currentTarget = nil; return end
		hum:MoveTo(tRoot.Position)
		local dy = tRoot.Position.Y - root.Position.Y
		if dy > JUMP_HEIGHT_THRESHOLD and now - lastJump >= JUMP_COOLDOWN then
			lastJump = now; hum.Jump = true
		end
	end)
end

local function stopTracking()
	if trackConn then trackConn:Disconnect(); trackConn = nil end
	currentTarget = nil
	local h, r = getHum(), getRoot()
	if h and r then h:MoveTo(r.Position) end
end

-- -----------------------------------------------------
--  AUTO GET BOMB LOGIC
-- -----------------------------------------------------

-- Reads the countdown from the exact known path:
-- Bomb.BombHandle.UIAttachment.UI.TimeLeft (TextLabel)
local function findCountdownNumber(char)
	local bomb = char:FindFirstChild("Bomb")
	if not bomb then return nil, nil end

	local handle = bomb:FindFirstChild("BombHandle")
	if not handle then return nil, nil end

	local attachment = handle:FindFirstChild("UIAttachment")
	if not attachment then return nil, nil end

	local ui = attachment:FindFirstChild("UI")
	if not ui then return nil, nil end

	local label = ui:FindFirstChild("TimeLeft")
	if not label or not label:IsA("TextLabel") then return nil, nil end

	local txt = label.Text
	if not txt or txt == "" then return nil, nil end

	local n = tonumber(txt:match("(%d+%.?%d*)"))
	return n, txt
end

-- Arena helpers
-- Reads Player.Data.ActiveArena.Value regardless of ValueBase type.
-- Returns nil when the player is NOT in an arena (value is nil or "nil").
-- Returns the raw value when in an arena - we store it as-is so that
-- comparing two players' arena values works correctly for any type
-- (same Instance reference, same number, same string, etc.)
local function getArenaValue(player)
	local data = player:FindFirstChild("Data")
	if not data then return nil end
	local av = data:FindFirstChild("ActiveArena")
	if not av then return nil end

	local raw = av.Value

	-- nil raw value = not in arena
	if raw == nil then return nil end

	-- If it's a string type, check for literal "nil" or empty
	local s = tostring(raw)
	if s == "nil" or s == "" then return nil end

	-- Return the raw value itself - Instance == Instance comparison works,
	-- string == string works, number == number works
	return raw
end

local function getLocalArena()
	return getArenaValue(LocalPlayer)
end

local function getPlayerArena(player)
	return getArenaValue(player)
end

local autoBombStatusVal  -- forward declared, assigned after GUI

local function startAutoBomb()
	if autoBombConn then return end

	autoBombConn = RunService.Heartbeat:Connect(function()
		local root, hum = getRoot(), getHum()
		if not root or not hum or hum.Health <= 0 then return end

		-- Arena check
		local myArena = getLocalArena()
		if not myArena then
			if autoBombStatusVal then
				autoBombStatusVal.Text       = "NO ARENA"
				autoBombStatusVal.TextColor3 = Color3.fromRGB(90, 90, 90)
			end
			hum:MoveTo(root.Position)
			return
		end

		-- Already holding bomb - let Auto Track take over, just update status
		if localHasTool() then
			if autoBombStatusVal then
				autoBombStatusVal.Text       = "HOLDING BOMB"
				autoBombStatusVal.TextColor3 = Color3.fromRGB(200, 200, 200)
			end
			return
		end

		-- Find nearest player who has a Bomb tool equipped, same arena, within studs range
		local bestCarrier, bestChar, bestDist = nil, nil, math.huge
		for _, p in ipairs(Players:GetPlayers()) do
			if p == LocalPlayer then continue end
			local char = p.Character
			if not char then continue end
			local pRoot = char:FindFirstChild("HumanoidRootPart")
			local pHum  = char:FindFirstChildOfClass("Humanoid")
			if not pRoot or not pHum or pHum.Health <= 0 then continue end

			-- Must share same ActiveArena
			local theirArena = getPlayerArena(p)
			if theirArena ~= myArena then continue end

			-- Must have "Bomb" tool equipped in their character
			local bombTool = char:FindFirstChild("Bomb")
			if not bombTool or not bombTool:IsA("Tool") then continue end

			local dist = (pRoot.Position - root.Position).Magnitude

			-- Must be within configured studs range
			if dist > AUTOBOMB_STUDS then continue end

			if dist < bestDist then
				bestDist = dist; bestCarrier = p; bestChar = char
			end
		end

		if not bestCarrier then
			if autoBombStatusVal then
				autoBombStatusVal.Text       = "NO BOMB"
				autoBombStatusVal.TextColor3 = Color3.fromRGB(90, 90, 90)
			end
			hum:MoveTo(root.Position)
			return
		end

		local carrierRoot = bestChar:FindFirstChild("HumanoidRootPart")
		if not carrierRoot then return end

		-- Read countdown on the bomb carrier
		local countNum, countTxt = findCountdownNumber(bestChar)
		-- Never grab at 1 sec or below - too dangerous, player will die
		local tooLate = countNum ~= nil and countNum <= 1
		local shouldGo = not tooLate and ((countNum == nil) or (countNum <= AUTOBOMB_COUNTDOWN))

		if shouldGo then
			hum:MoveTo(carrierRoot.Position)
			if autoBombStatusVal then
				local label = countTxt and ("GRABBING " .. countTxt) or "GRABBING"
				autoBombStatusVal.Text       = label .. "  [" .. math.floor(bestDist) .. "st]"
				autoBombStatusVal.TextColor3 = Color3.fromRGB(180, 180, 180)
			end
		elseif tooLate then
			hum:MoveTo(root.Position)
			if autoBombStatusVal then
				autoBombStatusVal.Text       = "TOO LATE  " .. (countTxt or "1")
				autoBombStatusVal.TextColor3 = Color3.fromRGB(200, 80, 80)
			end
		else
			-- Countdown not low enough yet - wait in place
			hum:MoveTo(root.Position)
			if autoBombStatusVal then
				autoBombStatusVal.Text       = "WAITING  " .. (countTxt or "")
				autoBombStatusVal.TextColor3 = Color3.fromRGB(160, 160, 160)
			end
		end
	end)
end

local function stopAutoBomb()
	if autoBombConn then autoBombConn:Disconnect(); autoBombConn = nil end
	local h, r = getHum(), getRoot()
	if h and r then h:MoveTo(r.Position) end
	if autoBombStatusVal then
		autoBombStatusVal.Text       = "-"
		autoBombStatusVal.TextColor3 = Color3.fromRGB(180, 180, 180)
	end
end

-- =====================================================
--  DOUBLE JUMP  (one extra jump while airborne)
-- =====================================================

local doubleJumpInputConn = nil

local function stopDoubleJump()
	if doubleJumpConn then doubleJumpConn:Disconnect(); doubleJumpConn = nil end
	if doubleJumpInputConn then doubleJumpInputConn:Disconnect(); doubleJumpInputConn = nil end
	doubleJumpUsed = false
end

local function startDoubleJump()
	if doubleJumpConn then return end
	doubleJumpUsed = false

	-- Track when the player last touched the ground so we don't
	-- accidentally fire the double jump on the same frame as the normal jump
	local landedAt = tick()

	doubleJumpConn = RunService.Heartbeat:Connect(function()
		local hum = getHum()
		if not hum then return end
		local state = hum:GetState()
		if state == Enum.HumanoidStateType.Landed
		or state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Seated then
			doubleJumpUsed = false
			landedAt = tick()
		end
	end)

	-- JumpRequest fires on mobile jump button AND keyboard space
	doubleJumpInputConn = game:GetService("UserInputService").JumpRequest:Connect(function()
		if not doubleJumpOn then return end
		-- Must be at least 0.2s after last landing so normal jump doesn't eat the charge
		if tick() - landedAt < 0.2 then return end

		local hum = getHum()
		local root = getRoot()
		if not hum or not root then return end

		-- Strictly only fire while actually airborne
		local state = hum:GetState()
		local airborne = state == Enum.HumanoidStateType.Freefall
			or state == Enum.HumanoidStateType.Jumping

		if airborne and not doubleJumpUsed then
			doubleJumpUsed = true
			local vel = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(vel.X, hum.JumpPower * DOUBLE_JUMP_POWER, vel.Z)
		end
	end)
end

-- =====================================================
--  TWEEN HELPER
-- =====================================================

local function tw(obj, props, t, style, dir)
	TweenService:Create(obj,
		TweenInfo.new(t or 0.2, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out),
		props
	):Play()
end

-- =====================================================
--  SCREENGUI
-- =====================================================

local SG = Instance.new("ScreenGui")
SG.Name           = "AutoTrackGui"
SG.ResetOnSpawn   = false
SG.DisplayOrder   = 999
SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SG.Parent         = LocalPlayer:WaitForChild("PlayerGui")

-- Line ESP container (full screen, behind everything)
local LineContainer = Instance.new("Frame", SG)
LineContainer.Name                   = "LineEspContainer"
LineContainer.Size                   = UDim2.new(1, 0, 1, 0)
LineContainer.BackgroundTransparency = 1
LineContainer.ZIndex                 = 1

-- -----------------------------------------------------
--  LINE ESP LOGIC  (declared here, uses LineContainer)
-- -----------------------------------------------------

local Camera = workspace.CurrentCamera

local ESP_FILL_COLOR    = Color3.fromRGB(230, 230, 230)
local ESP_OUTLINE_COLOR = Color3.fromRGB(255, 200, 200)

-- -- Safe cleanup for one player -----------------------
local function removeEspForPlayer(p)
	local entry = lineEspLines[p]
	if entry and entry.line and entry.line.Parent then
		entry.line:Destroy()
	end
	lineEspLines[p] = nil

	local hl = lineEspHighlights[p]
	if hl and hl.Parent then hl:Destroy() end
	lineEspHighlights[p] = nil
end

local function clearAllEsp()
	-- collect keys first so we don't mutate while iterating
	local keys = {}
	for p in pairs(lineEspLines) do keys[#keys+1] = p end
	for _, p in ipairs(keys) do removeEspForPlayer(p) end

	-- catch any orphan highlights
	local hkeys = {}
	for p in pairs(lineEspHighlights) do hkeys[#hkeys+1] = p end
	for _, p in ipairs(hkeys) do
		local hl = lineEspHighlights[p]
		if hl and hl.Parent then hl:Destroy() end
		lineEspHighlights[p] = nil
	end
end

local function stopLineEsp()
	if lineEspConn then lineEspConn:Disconnect(); lineEspConn = nil end
	clearAllEsp()
end

local function startLineEsp()
	if lineEspConn then return end

	lineEspConn = RunService.RenderStepped:Connect(function()
		local myRoot = getRoot()
		if not myRoot then return end

		-- Use UpperTorso (R15) or Torso (R6) for the local player origin.
		-- HumanoidRootPart sits at foot level so we grab the actual torso part.
		local myChar   = LocalPlayer.Character
		local myTorso  = myChar and (
			myChar:FindFirstChild("UpperTorso") or  -- R15
			myChar:FindFirstChild("Torso")          -- R6
		)
		local myOriginPart = myTorso or myRoot  -- fallback to HRP if neither found

		-- Project LocalPlayer's torso to screen
		local myScreenRaw, myOnScreen = Camera:WorldToViewportPoint(myOriginPart.Position)
		local vp = Camera.ViewportSize
		local originScreen
		if myOnScreen and myScreenRaw.Z > 0 then
			originScreen = Vector2.new(myScreenRaw.X, myScreenRaw.Y)
		else
			originScreen = Vector2.new(vp.X / 2, vp.Y / 2)
		end

		-- -- Build valid target set (world-space 15 stud radius) ---
		local validPlayers = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p == LocalPlayer then continue end
			local char = p.Character
			if not char then continue end
			local pRoot = char:FindFirstChild("HumanoidRootPart")
			local pHum  = char:FindFirstChildOfClass("Humanoid")
			if not pRoot or not pHum or pHum.Health <= 0 then continue end

			if hasHighlight(char) then continue end

			-- Distance check uses HRP (most reliable, always exists)
			local dist = (pRoot.Position - myRoot.Position).Magnitude
			if dist > LINE_ESP_DISTANCE then continue end

			-- Grab their torso for the line endpoint (R15 -> UpperTorso, R6 -> Torso)
			local pTorso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or pRoot

			validPlayers[p] = { root = pRoot, torso = pTorso, char = char, dist = dist }
		end

		-- -- Remove stale entries (collect keys first to avoid mutation) --
		local stale = {}
		for p in pairs(lineEspLines) do
			if not validPlayers[p] then stale[#stale+1] = p end
		end
		for _, p in ipairs(stale) do removeEspForPlayer(p) end

		local staleH = {}
		for p in pairs(lineEspHighlights) do
			if not validPlayers[p] then staleH[#staleH+1] = p end
		end
		for _, p in ipairs(staleH) do
			local hl = lineEspHighlights[p]
			if hl and hl.Parent then hl:Destroy() end
			lineEspHighlights[p] = nil
		end

		-- -- Create / update per-player ESP -----------------------
		for p, info in pairs(validPlayers) do

			-- Character Highlight outline - created once per player
			-- Tagged with ESP_TAG so hasHighlight ignores it (FLICKER FIX)
			if not lineEspHighlights[p] or not lineEspHighlights[p].Parent then
				local hl = Instance.new("Highlight")
				hl:SetAttribute(ESP_TAG, true)   -- mark as ours
				hl.FillColor           = ESP_FILL_COLOR
				hl.OutlineColor        = ESP_OUTLINE_COLOR
				hl.FillTransparency    = 0.72
				hl.OutlineTransparency = 0.0
				hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
				hl.Adornee             = info.char
				hl.Parent              = info.char
				lineEspHighlights[p]   = hl
			end

			-- Tracer line - created once, updated every frame
			if not lineEspLines[p] then
				local line = Instance.new("Frame")
				line.BackgroundColor3 = ESP_FILL_COLOR
				line.BorderSizePixel  = 0
				line.AnchorPoint      = Vector2.new(0.5, 0.5)
				line.ZIndex           = 200
				Instance.new("UICorner", line).CornerRadius = UDim.new(1, 0)
				line.Parent      = SG
				lineEspLines[p]  = { line = line }
			end

			local line = lineEspLines[p].line

			-- Project target TORSO to screen (not HRP/feet)
			local tScreenRaw, tOnScreen = Camera:WorldToViewportPoint(info.torso.Position)

			if not tOnScreen or tScreenRaw.Z < 0 then
				line.Visible = false
				continue
			end

			local targetScreen = Vector2.new(tScreenRaw.X, tScreenRaw.Y)
			line.Visible = true

			-- Line from originScreen -> targetScreen
			-- Position the frame at the midpoint, AnchorPoint(0.5,0.5) pivots there
			local dx  = targetScreen.X - originScreen.X
			local dy  = targetScreen.Y - originScreen.Y
			local len = math.sqrt(dx * dx + dy * dy)
			local ang = math.atan2(dy, dx) * (180 / math.pi) + 90

			local midX = (originScreen.X + targetScreen.X) * 0.5
			local midY = (originScreen.Y + targetScreen.Y) * 0.5

			line.Size     = UDim2.new(0, 2, 0, len)
			line.Position = UDim2.new(0, midX, 0, midY)
			line.Rotation = ang

			-- Red when close -> orange at edge of range
			local t = math.clamp(info.dist / LINE_ESP_DISTANCE, 0, 1)
			line.BackgroundColor3 = Color3.fromRGB(255, math.floor(55 + t * 145), 55)
		end
	end)
end

-- =====================================================
--  MAIN WINDOW
--  ClipsDescendants = false on Win itself.
--  WinClip (child frame) does the clipping so inner
--  content stays inside the rounded rect, but the
--  UIStroke / shadow sit outside fine.
-- =====================================================

local WIN_H = 346  -- main panel height

local Win = Instance.new("Frame", SG)
Win.Name             = "Window"
Win.Size             = UDim2.new(0, 240, 0, WIN_H)
Win.Position         = UDim2.new(0, 28, 0.5, -(WIN_H / 2))
Win.BackgroundColor3 = Color3.fromRGB(8, 8, 8)
Win.BorderSizePixel  = 0
Win.Active           = true
Win.Draggable        = true
Win.ClipsDescendants = false   -- OFF; WinClip handles clipping
Instance.new("UICorner", Win).CornerRadius = UDim.new(0, 16)

-- Inner clip mask - everything visible lives inside here
local WinClip = Instance.new("Frame", Win)
WinClip.Size                   = UDim2.new(1, 0, 1, 0)
WinClip.BackgroundTransparency = 1
WinClip.ClipsDescendants       = true
WinClip.ZIndex                 = 1
Instance.new("UICorner", WinClip).CornerRadius = UDim.new(0, 16)

-- Shadow (child of SG so it's truly outside the clip)
local ShadFrame = Instance.new("Frame", SG)
ShadFrame.Size             = UDim2.new(0, 276, 0, WIN_H + 36)
ShadFrame.Position         = UDim2.new(0, 10, 0.5, -((WIN_H / 2) + 18))
ShadFrame.BackgroundTransparency = 1
ShadFrame.ZIndex           = 0
local Shad = Instance.new("ImageLabel", ShadFrame)
Shad.AnchorPoint           = Vector2.new(0.5, 0.5)
Shad.BackgroundTransparency = 1
Shad.Position              = UDim2.new(0.5, 0, 0.5, 0)
Shad.Size                  = UDim2.new(1, 0, 1, 0)
Shad.ZIndex                = 0
Shad.Image                 = "rbxassetid://6014261993"
Shad.ImageColor3           = Color3.fromRGB(0, 0, 0)
Shad.ImageTransparency     = 0.34
Shad.ScaleType             = Enum.ScaleType.Slice
Shad.SliceCenter           = Rect.new(49, 49, 450, 450)

-- Border stroke on Win (renders outside WinClip, which is correct)
local WinStroke = Instance.new("UIStroke", Win)
WinStroke.Color           = Color3.fromRGB(230, 230, 230)
WinStroke.Thickness       = 1.5
WinStroke.Transparency    = 0.62
WinStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

-- Top accent bar (inside WinClip)
local TopAccent = Instance.new("Frame", WinClip)
TopAccent.Size             = UDim2.new(0.45, 0, 0, 2)
TopAccent.Position         = UDim2.new(0.275, 0, 0, 0)
TopAccent.BackgroundColor3 = Color3.fromRGB(230, 230, 230)
TopAccent.BorderSizePixel  = 0
TopAccent.ZIndex           = 10
Instance.new("UICorner", TopAccent).CornerRadius = UDim.new(0, 2)

-- -- Header --------------------------------------------
local Hdr = Instance.new("Frame", WinClip)
Hdr.Size             = UDim2.new(1, 0, 0, 44)
Hdr.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
Hdr.BorderSizePixel  = 0
Hdr.ZIndex           = 2

-- Header separator
local HdrLine = Instance.new("Frame", WinClip)
HdrLine.Size             = UDim2.new(1, 0, 0, 1)
HdrLine.Position         = UDim2.new(0, 0, 0, 44)
HdrLine.BackgroundColor3 = Color3.fromRGB(36, 36, 36)
HdrLine.BorderSizePixel  = 0
HdrLine.ZIndex           = 3

-- Pulse dot
local PulseDot = Instance.new("Frame", Hdr)
PulseDot.Size             = UDim2.new(0, 7, 0, 7)
PulseDot.Position         = UDim2.new(0, 14, 0.5, -3)
PulseDot.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
PulseDot.BorderSizePixel  = 0
PulseDot.ZIndex           = 5
Instance.new("UICorner", PulseDot).CornerRadius = UDim.new(1, 0)

local PulseRing = Instance.new("Frame", Hdr)
PulseRing.Size             = UDim2.new(0, 7, 0, 7)
PulseRing.Position         = UDim2.new(0, 14, 0.5, -3)
PulseRing.BackgroundTransparency = 1
PulseRing.ZIndex           = 4
Instance.new("UICorner", PulseRing).CornerRadius = UDim.new(1, 0)
local PulseStroke = Instance.new("UIStroke", PulseRing)
PulseStroke.Color        = Color3.fromRGB(230, 230, 230)
PulseStroke.Thickness    = 1.5
PulseStroke.Transparency = 1

-- Title
local TitleLbl = Instance.new("TextLabel", Hdr)
TitleLbl.Size               = UDim2.new(1, -90, 1, 0)
TitleLbl.Position           = UDim2.new(0, 30, 0, 0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.Text               = "AUTO TRACK"
TitleLbl.TextColor3         = Color3.fromRGB(240, 240, 240)
TitleLbl.TextSize           = 12
TitleLbl.Font               = Enum.Font.GothamBold
TitleLbl.TextXAlignment     = Enum.TextXAlignment.Left
TitleLbl.ZIndex             = 5

-- Version badge
local Ver = Instance.new("TextLabel", Hdr)
Ver.Size                  = UDim2.new(0, 26, 0, 14)
Ver.Position              = UDim2.new(1, -34, 0.5, -7)
Ver.BackgroundColor3      = Color3.fromRGB(230, 230, 230)
Ver.BackgroundTransparency = 0.68
Ver.Text                  = "v1"
Ver.TextColor3            = Color3.fromRGB(200, 200, 200)
Ver.TextSize              = 9
Ver.Font                  = Enum.Font.GothamBold
Ver.ZIndex                = 5
Instance.new("UICorner", Ver).CornerRadius = UDim.new(0, 4)

-- Settings button
local SettingsBtn = Instance.new("TextButton", Hdr)
SettingsBtn.Size             = UDim2.new(0, 52, 0, 22)
SettingsBtn.Position         = UDim2.new(1, -96, 0.5, -11)
SettingsBtn.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
SettingsBtn.Text             = "Settings"
SettingsBtn.TextColor3       = Color3.fromRGB(130, 130, 130)
SettingsBtn.TextSize         = 9
SettingsBtn.Font             = Enum.Font.GothamBold
SettingsBtn.BorderSizePixel  = 0
SettingsBtn.AutoButtonColor  = false
SettingsBtn.ZIndex           = 6
Instance.new("UICorner", SettingsBtn).CornerRadius = UDim.new(0, 6)
local SettingsBtnStroke = Instance.new("UIStroke", SettingsBtn)
SettingsBtnStroke.Color        = Color3.fromRGB(60, 60, 60)
SettingsBtnStroke.Thickness    = 1
SettingsBtnStroke.Transparency = 0.4

-- =====================================================
--  TAB CONTAINER  (inside WinClip so it clips to window)
-- =====================================================

local TabContainer = Instance.new("Frame", WinClip)
TabContainer.Size             = UDim2.new(2, 0, 1, -45)
TabContainer.Position         = UDim2.new(0, 0, 0, 45)
TabContainer.BackgroundTransparency = 1

-- -- MAIN PANEL ---------------------------------------
local MainPanel = Instance.new("Frame", TabContainer)
MainPanel.Size             = UDim2.new(0, 240, 1, 0)
MainPanel.Position         = UDim2.new(0, 0, 0, 0)
MainPanel.BackgroundTransparency = 1

local function makeRow(parent, labelTxt, yOff)
	local row = Instance.new("Frame", parent)
	row.Size               = UDim2.new(1, -24, 0, 15)
	row.Position           = UDim2.new(0, 12, 0, yOff)
	row.BackgroundTransparency = 1
	local k = Instance.new("TextLabel", row)
	k.Size               = UDim2.new(0, 60, 1, 0)
	k.BackgroundTransparency = 1
	k.Text               = labelTxt
	k.TextColor3         = Color3.fromRGB(75, 75, 75)
	k.TextSize           = 9
	k.Font               = Enum.Font.GothamBold
	k.TextXAlignment     = Enum.TextXAlignment.Left
	local v = Instance.new("TextLabel", row)
	v.Size               = UDim2.new(1, -64, 1, 0)
	v.Position           = UDim2.new(0, 64, 0, 0)
	v.BackgroundTransparency = 1
	v.Text               = "-"
	v.TextColor3         = Color3.fromRGB(180, 180, 180)
	v.TextSize           = 9
	v.Font               = Enum.Font.GothamBold
	v.TextXAlignment     = Enum.TextXAlignment.Left
	return v
end

local TargetVal = makeRow(MainPanel, "TARGET", 8)
local StatusVal = makeRow(MainPanel, "STATUS", 24)

local Div = Instance.new("Frame", MainPanel)
Div.Size             = UDim2.new(1, -24, 0, 1)
Div.Position         = UDim2.new(0, 12, 0, 44)
Div.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
Div.BorderSizePixel  = 0

-- -- JOIN DISCORD Button ------------------------------
local DiscordBtn = Instance.new("TextButton", MainPanel)
DiscordBtn.Size             = UDim2.new(1, -24, 0, 30)
DiscordBtn.Position         = UDim2.new(0, 12, 0, 52)
DiscordBtn.BackgroundColor3 = Color3.fromRGB(16, 16, 16)
DiscordBtn.Text             = ""
DiscordBtn.BorderSizePixel  = 0
DiscordBtn.AutoButtonColor  = false
Instance.new("UICorner", DiscordBtn).CornerRadius = UDim.new(0, 8)

local DiscordStroke = Instance.new("UIStroke", DiscordBtn)
DiscordStroke.Color        = Color3.fromRGB(55, 55, 55)
DiscordStroke.Thickness    = 1
DiscordStroke.Transparency = 0.3

local DiscordIcon = Instance.new("TextLabel", DiscordBtn)
DiscordIcon.Size               = UDim2.new(0, 20, 1, 0)
DiscordIcon.Position           = UDim2.new(0, 10, 0, 0)
DiscordIcon.BackgroundTransparency = 1
DiscordIcon.Text               = "🔗"
DiscordIcon.TextSize           = 12
DiscordIcon.Font               = Enum.Font.GothamBold
DiscordIcon.ZIndex             = 4

local DiscordLabel = Instance.new("TextLabel", DiscordBtn)
DiscordLabel.Size               = UDim2.new(1, -70, 1, 0)
DiscordLabel.Position           = UDim2.new(0, 34, 0, 0)
DiscordLabel.BackgroundTransparency = 1
DiscordLabel.Text               = "Join Discord"
DiscordLabel.TextColor3         = Color3.fromRGB(155, 155, 155)
DiscordLabel.TextSize           = 10
DiscordLabel.Font               = Enum.Font.GothamBold
DiscordLabel.TextXAlignment     = Enum.TextXAlignment.Left
DiscordLabel.ZIndex             = 4

local DiscordCopyLbl = Instance.new("TextLabel", DiscordBtn)
DiscordCopyLbl.Size               = UDim2.new(0, 42, 1, 0)
DiscordCopyLbl.Position           = UDim2.new(1, -46, 0, 0)
DiscordCopyLbl.BackgroundTransparency = 1
DiscordCopyLbl.Text               = "COPY"
DiscordCopyLbl.TextColor3         = Color3.fromRGB(80, 80, 80)
DiscordCopyLbl.TextSize           = 8
DiscordCopyLbl.Font               = Enum.Font.GothamBold
DiscordCopyLbl.TextXAlignment     = Enum.TextXAlignment.Right
DiscordCopyLbl.ZIndex             = 4

local DiscordDivider = Instance.new("Frame", MainPanel)
DiscordDivider.Size             = UDim2.new(1, -24, 0, 1)
DiscordDivider.Position         = UDim2.new(0, 12, 0, 90)
DiscordDivider.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
DiscordDivider.BorderSizePixel  = 0

-- -- AUTO TRACK Button --------------------------------
-- BtnClip: clips the shimmer so it can't bleed outside
local BtnClip = Instance.new("Frame", MainPanel)
BtnClip.Size             = UDim2.new(1, -24, 0, 36)
BtnClip.Position         = UDim2.new(0, 12, 0, 98)
BtnClip.BackgroundTransparency = 1
BtnClip.ClipsDescendants = true
Instance.new("UICorner", BtnClip).CornerRadius = UDim.new(0, 10)

local Btn = Instance.new("TextButton", BtnClip)
Btn.Size             = UDim2.new(1, 0, 1, 0)
Btn.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
Btn.Text             = ""
Btn.BorderSizePixel  = 0
Btn.AutoButtonColor  = false
Instance.new("UICorner", Btn).CornerRadius = UDim.new(0, 10)

local BtnStroke = Instance.new("UIStroke", Btn)
BtnStroke.Color        = Color3.fromRGB(50, 50, 50)
BtnStroke.Thickness    = 1
BtnStroke.Transparency = 0.35

-- Shimmer lives INSIDE BtnClip - cannot escape
local BtnShimmer = Instance.new("Frame", BtnClip)
BtnShimmer.Size             = UDim2.new(0, 80, 1, 0)
BtnShimmer.Position         = UDim2.new(-0.6, 0, 0, 0)
BtnShimmer.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
BtnShimmer.BackgroundTransparency = 0.9
BtnShimmer.BorderSizePixel  = 0
BtnShimmer.ZIndex           = 3
Instance.new("UICorner", BtnShimmer).CornerRadius = UDim.new(0, 10)

local BtnPill = Instance.new("Frame", Btn)
BtnPill.Size             = UDim2.new(0, 7, 0, 7)
BtnPill.Position         = UDim2.new(0, 12, 0.5, -3)
BtnPill.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
BtnPill.BorderSizePixel  = 0
BtnPill.ZIndex           = 4
Instance.new("UICorner", BtnPill).CornerRadius = UDim.new(1, 0)

local BtnText = Instance.new("TextLabel", Btn)
BtnText.Size               = UDim2.new(1, -30, 1, 0)
BtnText.Position           = UDim2.new(0, 28, 0, 0)
BtnText.BackgroundTransparency = 1
BtnText.Text               = "ENABLE"
BtnText.TextColor3         = Color3.fromRGB(145, 145, 145)
BtnText.TextSize           = 11
BtnText.Font               = Enum.Font.GothamBold
BtnText.TextXAlignment     = Enum.TextXAlignment.Left
BtnText.ZIndex             = 4

-- Hold bar inside BtnClip
local HoldBar = Instance.new("Frame", BtnClip)
HoldBar.Size             = UDim2.new(0, 0, 0, 2)
HoldBar.Position         = UDim2.new(0, 0, 1, -2)
HoldBar.BackgroundColor3 = Color3.fromRGB(230, 230, 230)
HoldBar.BorderSizePixel  = 0
HoldBar.ZIndex           = 5
Instance.new("UICorner", HoldBar).CornerRadius = UDim.new(0, 1)

-- Divider between toggles
local Div2 = Instance.new("Frame", MainPanel)
Div2.Size             = UDim2.new(1, -24, 0, 1)
Div2.Position         = UDim2.new(0, 12, 0, 143)
Div2.BackgroundColor3 = Color3.fromRGB(38, 38, 38)
Div2.BorderSizePixel  = 0

-- -- AUTO GET BOMB Card (main panel) -----------------
local BombCard = Instance.new("Frame", MainPanel)
BombCard.Size             = UDim2.new(1, -24, 0, 80)
BombCard.Position         = UDim2.new(0, 12, 0, 152)
BombCard.BackgroundColor3 = Color3.fromRGB(14, 14, 14)
BombCard.BorderSizePixel  = 0
Instance.new("UICorner", BombCard).CornerRadius = UDim.new(0, 10)
local BombCardStroke = Instance.new("UIStroke", BombCard)
BombCardStroke.Color        = Color3.fromRGB(50, 50, 50)
BombCardStroke.Thickness    = 1
BombCardStroke.Transparency = 0.3

-- Pill dot
local BombDot = Instance.new("Frame", BombCard)
BombDot.Size             = UDim2.new(0, 6, 0, 6)
BombDot.Position         = UDim2.new(0, 12, 0, 10)
BombDot.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
BombDot.BorderSizePixel  = 0
BombDot.ZIndex           = 4
Instance.new("UICorner", BombDot).CornerRadius = UDim.new(1, 0)

-- Label + toggle
local BombLabel = Instance.new("TextLabel", BombCard)
BombLabel.Size               = UDim2.new(1, -58, 0, 16)
BombLabel.Position           = UDim2.new(0, 26, 0, 4)
BombLabel.BackgroundTransparency = 1
BombLabel.Text               = "Auto Get Bomb"
BombLabel.TextColor3         = Color3.fromRGB(175, 175, 175)
BombLabel.TextSize           = 10
BombLabel.Font               = Enum.Font.GothamBold
BombLabel.TextXAlignment     = Enum.TextXAlignment.Left

local BombToggle = Instance.new("TextButton", BombCard)
BombToggle.Size             = UDim2.new(0, 36, 0, 18)
BombToggle.Position         = UDim2.new(1, -44, 0, 4)
BombToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
BombToggle.Text             = ""
BombToggle.BorderSizePixel  = 0
BombToggle.AutoButtonColor  = false
BombToggle.ZIndex           = 6
Instance.new("UICorner", BombToggle).CornerRadius = UDim.new(1, 0)
local BombToggleStroke = Instance.new("UIStroke", BombToggle)
BombToggleStroke.Color        = Color3.fromRGB(60, 60, 60)
BombToggleStroke.Thickness    = 1
BombToggleStroke.Transparency = 0.2
local BombThumb = Instance.new("Frame", BombToggle)
BombThumb.Size             = UDim2.new(0, 12, 0, 12)
BombThumb.Position         = UDim2.new(0, 3, 0.5, -6)
BombThumb.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
BombThumb.BorderSizePixel  = 0
BombThumb.ZIndex           = 7
Instance.new("UICorner", BombThumb).CornerRadius = UDim.new(1, 0)

-- Divider line inside card
local BombCardDiv = Instance.new("Frame", BombCard)
BombCardDiv.Size             = UDim2.new(1, -24, 0, 1)
BombCardDiv.Position         = UDim2.new(0, 12, 0, 26)
BombCardDiv.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
BombCardDiv.BorderSizePixel  = 0

-- Countdown row
local BombSubLabel = Instance.new("TextLabel", BombCard)
BombSubLabel.Size               = UDim2.new(0.52, 0, 0, 11)
BombSubLabel.Position           = UDim2.new(0, 12, 0, 32)
BombSubLabel.BackgroundTransparency = 1
BombSubLabel.Text               = "Grab when countdown <="
BombSubLabel.TextColor3         = Color3.fromRGB(70, 70, 70)
BombSubLabel.TextSize           = 8
BombSubLabel.Font               = Enum.Font.Gotham
BombSubLabel.TextXAlignment     = Enum.TextXAlignment.Left

local BombCountBox = Instance.new("TextBox", BombCard)
BombCountBox.Size               = UDim2.new(0, 36, 0, 19)
BombCountBox.Position           = UDim2.new(1, -84, 0, 29)
BombCountBox.BackgroundColor3   = Color3.fromRGB(20, 20, 20)
BombCountBox.Text               = "3"
BombCountBox.TextColor3         = Color3.fromRGB(210, 210, 210)
BombCountBox.TextSize           = 11
BombCountBox.Font               = Enum.Font.GothamBold
BombCountBox.ClearTextOnFocus   = false
BombCountBox.PlaceholderText    = "3"
BombCountBox.PlaceholderColor3  = Color3.fromRGB(70, 70, 70)
BombCountBox.BorderSizePixel    = 0
BombCountBox.ZIndex             = 6
BombCountBox.TextXAlignment     = Enum.TextXAlignment.Center
Instance.new("UICorner", BombCountBox).CornerRadius = UDim.new(0, 5)
local BombCountBoxStroke = Instance.new("UIStroke", BombCountBox)
BombCountBoxStroke.Color        = Color3.fromRGB(55, 55, 55)
BombCountBoxStroke.Thickness    = 1
BombCountBoxStroke.Transparency = 0.2

local BombCountUnit = Instance.new("TextLabel", BombCard)
BombCountUnit.Size               = UDim2.new(0, 22, 0, 19)
BombCountUnit.Position           = UDim2.new(1, -46, 0, 29)
BombCountUnit.BackgroundTransparency = 1
BombCountUnit.Text               = "sec"
BombCountUnit.TextColor3         = Color3.fromRGB(70, 70, 70)
BombCountUnit.TextSize           = 8
BombCountUnit.Font               = Enum.Font.Gotham
BombCountUnit.ZIndex             = 7

-- Studs row
local BombStudsLabel = Instance.new("TextLabel", BombCard)
BombStudsLabel.Size               = UDim2.new(0.52, 0, 0, 11)
BombStudsLabel.Position           = UDim2.new(0, 12, 0, 52)
BombStudsLabel.BackgroundTransparency = 1
BombStudsLabel.Text               = "Studs to carrier"
BombStudsLabel.TextColor3         = Color3.fromRGB(70, 70, 70)
BombStudsLabel.TextSize           = 8
BombStudsLabel.Font               = Enum.Font.Gotham
BombStudsLabel.TextXAlignment     = Enum.TextXAlignment.Left

local BombStudsBox = Instance.new("TextBox", BombCard)
BombStudsBox.Size               = UDim2.new(0, 36, 0, 19)
BombStudsBox.Position           = UDim2.new(1, -84, 0, 49)
BombStudsBox.BackgroundColor3   = Color3.fromRGB(20, 20, 20)
BombStudsBox.Text               = "15"
BombStudsBox.TextColor3         = Color3.fromRGB(210, 210, 210)
BombStudsBox.TextSize           = 11
BombStudsBox.Font               = Enum.Font.GothamBold
BombStudsBox.ClearTextOnFocus   = false
BombStudsBox.PlaceholderText    = "15"
BombStudsBox.PlaceholderColor3  = Color3.fromRGB(70, 70, 70)
BombStudsBox.BorderSizePixel    = 0
BombStudsBox.ZIndex             = 6
BombStudsBox.TextXAlignment     = Enum.TextXAlignment.Center
Instance.new("UICorner", BombStudsBox).CornerRadius = UDim.new(0, 5)
local BombStudsBoxStroke = Instance.new("UIStroke", BombStudsBox)
BombStudsBoxStroke.Color        = Color3.fromRGB(55, 55, 55)
BombStudsBoxStroke.Thickness    = 1
BombStudsBoxStroke.Transparency = 0.2

local BombStudsUnit = Instance.new("TextLabel", BombCard)
BombStudsUnit.Size               = UDim2.new(0, 22, 0, 19)
BombStudsUnit.Position           = UDim2.new(1, -46, 0, 49)
BombStudsUnit.BackgroundTransparency = 1
BombStudsUnit.Text               = "st"
BombStudsUnit.TextColor3         = Color3.fromRGB(70, 70, 70)
BombStudsUnit.TextSize           = 8
BombStudsUnit.Font               = Enum.Font.Gotham
BombStudsUnit.ZIndex             = 7

-- Status label at bottom of card
local BombStatusVal = Instance.new("TextLabel", BombCard)
BombStatusVal.Size               = UDim2.new(1, -24, 0, 11)
BombStatusVal.Position           = UDim2.new(0, 12, 1, -13)
BombStatusVal.BackgroundTransparency = 1
BombStatusVal.Text               = "-"
BombStatusVal.TextColor3         = Color3.fromRGB(90, 90, 90)
BombStatusVal.TextSize           = 8
BombStatusVal.Font               = Enum.Font.Gotham
BombStatusVal.TextXAlignment     = Enum.TextXAlignment.Left
BombStatusVal.ZIndex             = 4

-- -- SETTINGS PANEL ----------------------------------
local SettingsPanel = Instance.new("ScrollingFrame", TabContainer)
SettingsPanel.Size                = UDim2.new(0, 240, 1, 0)
SettingsPanel.Position            = UDim2.new(0, 240, 0, 0)
SettingsPanel.BackgroundTransparency = 1
SettingsPanel.CanvasSize          = UDim2.new(0, 0, 0, 258)
SettingsPanel.ScrollBarThickness  = 3
SettingsPanel.ScrollBarImageColor3 = Color3.fromRGB(230, 230, 230)
SettingsPanel.ScrollBarImageTransparency = 0.5
SettingsPanel.ScrollingDirection  = Enum.ScrollingDirection.Y
SettingsPanel.ElasticBehavior     = Enum.ElasticBehavior.Never
SettingsPanel.ClipsDescendants    = true

local BackBtn = Instance.new("TextButton", SettingsPanel)
BackBtn.Size             = UDim2.new(0, 56, 0, 22)
BackBtn.Position         = UDim2.new(0, 12, 0, 10)
BackBtn.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
BackBtn.Text             = "< BACK"
BackBtn.TextColor3       = Color3.fromRGB(150, 150, 150)
BackBtn.TextSize         = 9
BackBtn.Font             = Enum.Font.GothamBold
BackBtn.BorderSizePixel  = 0
BackBtn.AutoButtonColor  = false
BackBtn.ZIndex           = 6
Instance.new("UICorner", BackBtn).CornerRadius = UDim.new(0, 6)
local BackStroke = Instance.new("UIStroke", BackBtn)
BackStroke.Color        = Color3.fromRGB(60, 60, 60)
BackStroke.Thickness    = 1
BackStroke.Transparency = 0.4

local SettingsTitle = Instance.new("TextLabel", SettingsPanel)
SettingsTitle.Size               = UDim2.new(1, -24, 0, 22)
SettingsTitle.Position           = UDim2.new(0, 80, 0, 10)
SettingsTitle.BackgroundTransparency = 1
SettingsTitle.Text               = "SETTINGS"
SettingsTitle.TextColor3         = Color3.fromRGB(170, 170, 170)
SettingsTitle.TextSize           = 10
SettingsTitle.Font               = Enum.Font.GothamBold
SettingsTitle.TextXAlignment     = Enum.TextXAlignment.Left
SettingsTitle.ZIndex             = 5

local SDivider = Instance.new("Frame", SettingsPanel)
SDivider.Size             = UDim2.new(1, -24, 0, 1)
SDivider.Position         = UDim2.new(0, 12, 0, 38)
SDivider.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
SDivider.BorderSizePixel  = 0

-- Lock Mini row
local LockRow = Instance.new("Frame", SettingsPanel)
LockRow.Size               = UDim2.new(1, -24, 0, 34)
LockRow.Position           = UDim2.new(0, 12, 0, 48)
LockRow.BackgroundColor3   = Color3.fromRGB(12, 12, 12)
LockRow.BorderSizePixel    = 0
Instance.new("UICorner", LockRow).CornerRadius = UDim.new(0, 9)
local LockRowStroke = Instance.new("UIStroke", LockRow)
LockRowStroke.Color        = Color3.fromRGB(40, 40, 40)
LockRowStroke.Thickness    = 1
LockRowStroke.Transparency = 0.25

local LockLabel = Instance.new("TextLabel", LockRow)
LockLabel.Size               = UDim2.new(1, -52, 1, 0)
LockLabel.Position           = UDim2.new(0, 12, 0, 0)
LockLabel.BackgroundTransparency = 1
LockLabel.Text               = "Lock Mini Toggle"
LockLabel.TextColor3         = Color3.fromRGB(175, 175, 175)
LockLabel.TextSize           = 10
LockLabel.Font               = Enum.Font.GothamBold
LockLabel.TextXAlignment     = Enum.TextXAlignment.Left

local LockSubLabel = Instance.new("TextLabel", LockRow)
LockSubLabel.Size               = UDim2.new(1, -52, 0, 12)
LockSubLabel.Position           = UDim2.new(0, 12, 1, -13)
LockSubLabel.BackgroundTransparency = 1
LockSubLabel.Text               = "Prevents mini circle from moving"
LockSubLabel.TextColor3         = Color3.fromRGB(70, 70, 70)
LockSubLabel.TextSize           = 8
LockSubLabel.Font               = Enum.Font.Gotham
LockSubLabel.TextXAlignment     = Enum.TextXAlignment.Left

local LockToggle = Instance.new("TextButton", LockRow)
LockToggle.Size             = UDim2.new(0, 36, 0, 18)
LockToggle.Position         = UDim2.new(1, -44, 0.5, -9)
LockToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
LockToggle.Text             = ""
LockToggle.BorderSizePixel  = 0
LockToggle.AutoButtonColor  = false
LockToggle.ZIndex           = 6
Instance.new("UICorner", LockToggle).CornerRadius = UDim.new(1, 0)
local LockToggleStroke = Instance.new("UIStroke", LockToggle)
LockToggleStroke.Color        = Color3.fromRGB(60, 60, 60)
LockToggleStroke.Thickness    = 1
LockToggleStroke.Transparency = 0.2

local LockThumb = Instance.new("Frame", LockToggle)
LockThumb.Size             = UDim2.new(0, 12, 0, 12)
LockThumb.Position         = UDim2.new(0, 3, 0.5, -6)
LockThumb.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
LockThumb.BorderSizePixel  = 0
LockThumb.ZIndex           = 7
Instance.new("UICorner", LockThumb).CornerRadius = UDim.new(1, 0)

-- -- Double Jump row (replaces Hitbox Expander) -------
local DJDivider = Instance.new("Frame", SettingsPanel)
DJDivider.Size             = UDim2.new(1, -24, 0, 1)
DJDivider.Position         = UDim2.new(0, 12, 0, 90)
DJDivider.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
DJDivider.BorderSizePixel  = 0

local DJRow = Instance.new("Frame", SettingsPanel)
DJRow.Size               = UDim2.new(1, -24, 0, 44)
DJRow.Position           = UDim2.new(0, 12, 0, 99)
DJRow.BackgroundColor3   = Color3.fromRGB(12, 12, 12)
DJRow.BorderSizePixel    = 0
Instance.new("UICorner", DJRow).CornerRadius = UDim.new(0, 9)
local DJRowStroke = Instance.new("UIStroke", DJRow)
DJRowStroke.Color        = Color3.fromRGB(40, 40, 40)
DJRowStroke.Thickness    = 1
DJRowStroke.Transparency = 0.25

local DJDot = Instance.new("Frame", DJRow)
DJDot.Size             = UDim2.new(0, 6, 0, 6)
DJDot.Position         = UDim2.new(0, 12, 0.5, -3)
DJDot.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
DJDot.BorderSizePixel  = 0
DJDot.ZIndex           = 4
Instance.new("UICorner", DJDot).CornerRadius = UDim.new(1, 0)

local DJLabel = Instance.new("TextLabel", DJRow)
DJLabel.Size               = UDim2.new(1, -58, 0, 16)
DJLabel.Position           = UDim2.new(0, 26, 0, 5)
DJLabel.BackgroundTransparency = 1
DJLabel.Text               = "Double Jump"
DJLabel.TextColor3         = Color3.fromRGB(175, 175, 175)
DJLabel.TextSize           = 10
DJLabel.Font               = Enum.Font.GothamBold
DJLabel.TextXAlignment     = Enum.TextXAlignment.Left

local DJSubLabel = Instance.new("TextLabel", DJRow)
DJSubLabel.Size               = UDim2.new(1, -58, 0, 11)
DJSubLabel.Position           = UDim2.new(0, 26, 1, -14)
DJSubLabel.BackgroundTransparency = 1
DJSubLabel.Text               = "One extra jump while airborne"
DJSubLabel.TextColor3         = Color3.fromRGB(70, 70, 70)
DJSubLabel.TextSize           = 8
DJSubLabel.Font               = Enum.Font.Gotham
DJSubLabel.TextXAlignment     = Enum.TextXAlignment.Left

local DJToggle = Instance.new("TextButton", DJRow)
DJToggle.Size             = UDim2.new(0, 36, 0, 18)
DJToggle.Position         = UDim2.new(1, -44, 0.5, -9)
DJToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
DJToggle.Text             = ""
DJToggle.BorderSizePixel  = 0
DJToggle.AutoButtonColor  = false
DJToggle.ZIndex           = 6
Instance.new("UICorner", DJToggle).CornerRadius = UDim.new(1, 0)
local DJToggleStroke = Instance.new("UIStroke", DJToggle)
DJToggleStroke.Color        = Color3.fromRGB(60, 60, 60)
DJToggleStroke.Thickness    = 1
DJToggleStroke.Transparency = 0.2

local DJThumb = Instance.new("Frame", DJToggle)
DJThumb.Size             = UDim2.new(0, 12, 0, 12)
DJThumb.Position         = UDim2.new(0, 3, 0.5, -6)
DJThumb.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
DJThumb.BorderSizePixel  = 0
DJThumb.ZIndex           = 7
Instance.new("UICorner", DJThumb).CornerRadius = UDim.new(1, 0)

-- -- DJ Power textbox row -----------------------------
local DJPowerDivider = Instance.new("Frame", SettingsPanel)
DJPowerDivider.Size             = UDim2.new(1, -24, 0, 1)
DJPowerDivider.Position         = UDim2.new(0, 12, 0, 151)
DJPowerDivider.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
DJPowerDivider.BorderSizePixel  = 0

local DJPowerRow = Instance.new("Frame", SettingsPanel)
DJPowerRow.Size               = UDim2.new(1, -24, 0, 34)
DJPowerRow.Position           = UDim2.new(0, 12, 0, 160)
DJPowerRow.BackgroundColor3   = Color3.fromRGB(12, 12, 12)
DJPowerRow.BorderSizePixel    = 0
Instance.new("UICorner", DJPowerRow).CornerRadius = UDim.new(0, 9)
local DJPowerRowStroke = Instance.new("UIStroke", DJPowerRow)
DJPowerRowStroke.Color        = Color3.fromRGB(40, 40, 40)
DJPowerRowStroke.Thickness    = 1
DJPowerRowStroke.Transparency = 0.25

local DJPowerLabel = Instance.new("TextLabel", DJPowerRow)
DJPowerLabel.Size               = UDim2.new(0.55, 0, 1, 0)
DJPowerLabel.Position           = UDim2.new(0, 12, 0, 0)
DJPowerLabel.BackgroundTransparency = 1
DJPowerLabel.Text               = "Jump Power"
DJPowerLabel.TextColor3         = Color3.fromRGB(175, 175, 175)
DJPowerLabel.TextSize           = 10
DJPowerLabel.Font               = Enum.Font.GothamBold
DJPowerLabel.TextXAlignment     = Enum.TextXAlignment.Left

local DJPowerBox = Instance.new("TextBox", DJPowerRow)
DJPowerBox.Size               = UDim2.new(0, 48, 0, 22)
DJPowerBox.Position           = UDim2.new(1, -58, 0.5, -11)
DJPowerBox.BackgroundColor3   = Color3.fromRGB(20, 16, 32)
DJPowerBox.Text               = "0.6"
DJPowerBox.TextColor3         = Color3.fromRGB(210, 210, 210)
DJPowerBox.TextSize           = 11
DJPowerBox.Font               = Enum.Font.GothamBold
DJPowerBox.ClearTextOnFocus   = false
DJPowerBox.PlaceholderText    = "0.6"
DJPowerBox.PlaceholderColor3  = Color3.fromRGB(80, 80, 80)
DJPowerBox.BorderSizePixel    = 0
DJPowerBox.ZIndex             = 6
DJPowerBox.TextXAlignment     = Enum.TextXAlignment.Center
Instance.new("UICorner", DJPowerBox).CornerRadius = UDim.new(0, 6)
local DJPowerBoxStroke = Instance.new("UIStroke", DJPowerBox)
DJPowerBoxStroke.Color        = Color3.fromRGB(55, 55, 55)
DJPowerBoxStroke.Thickness    = 1
DJPowerBoxStroke.Transparency = 0.2

local DJPowerUnit = Instance.new("TextLabel", DJPowerRow)
DJPowerUnit.Size               = UDim2.new(0, 16, 0, 14)
DJPowerUnit.Position           = UDim2.new(1, -12, 0.5, -7)
DJPowerUnit.BackgroundTransparency = 1
DJPowerUnit.Text               = "x"
DJPowerUnit.TextColor3         = Color3.fromRGB(80, 80, 80)
DJPowerUnit.TextSize           = 9
DJPowerUnit.Font               = Enum.Font.GothamBold
DJPowerUnit.ZIndex             = 7

-- -- Status Gui toggle row ----------------------------
local SGDivider = Instance.new("Frame", SettingsPanel)
SGDivider.Size             = UDim2.new(1, -24, 0, 1)
SGDivider.Position         = UDim2.new(0, 12, 0, 202)
SGDivider.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
SGDivider.BorderSizePixel  = 0

local SGRow = Instance.new("Frame", SettingsPanel)
SGRow.Size               = UDim2.new(1, -24, 0, 34)
SGRow.Position           = UDim2.new(0, 12, 0, 211)
SGRow.BackgroundColor3   = Color3.fromRGB(12, 12, 12)
SGRow.BorderSizePixel    = 0
Instance.new("UICorner", SGRow).CornerRadius = UDim.new(0, 9)
local SGRowStroke = Instance.new("UIStroke", SGRow)
SGRowStroke.Color        = Color3.fromRGB(40, 40, 40)
SGRowStroke.Thickness    = 1
SGRowStroke.Transparency = 0.25

local SGDot = Instance.new("Frame", SGRow)
SGDot.Size             = UDim2.new(0, 6, 0, 6)
SGDot.Position         = UDim2.new(0, 12, 0.5, -3)
SGDot.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
SGDot.BorderSizePixel  = 0
SGDot.ZIndex           = 4
Instance.new("UICorner", SGDot).CornerRadius = UDim.new(1, 0)

local SGLabel = Instance.new("TextLabel", SGRow)
SGLabel.Size               = UDim2.new(1, -58, 0, 16)
SGLabel.Position           = UDim2.new(0, 26, 0, 5)
SGLabel.BackgroundTransparency = 1
SGLabel.Text               = "Status Gui"
SGLabel.TextColor3         = Color3.fromRGB(175, 175, 175)
SGLabel.TextSize           = 10
SGLabel.Font               = Enum.Font.GothamBold
SGLabel.TextXAlignment     = Enum.TextXAlignment.Left

local SGSubLabel = Instance.new("TextLabel", SGRow)
SGSubLabel.Size               = UDim2.new(1, -58, 0, 11)
SGSubLabel.Position           = UDim2.new(0, 26, 1, -14)
SGSubLabel.BackgroundTransparency = 1
SGSubLabel.Text               = "Draggable status overlay"
SGSubLabel.TextColor3         = Color3.fromRGB(70, 70, 70)
SGSubLabel.TextSize           = 8
SGSubLabel.Font               = Enum.Font.Gotham
SGSubLabel.TextXAlignment     = Enum.TextXAlignment.Left

local SGToggle = Instance.new("TextButton", SGRow)
SGToggle.Size             = UDim2.new(0, 36, 0, 18)
SGToggle.Position         = UDim2.new(1, -44, 0.5, -9)
SGToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
SGToggle.Text             = ""
SGToggle.BorderSizePixel  = 0
SGToggle.AutoButtonColor  = false
SGToggle.ZIndex           = 6
Instance.new("UICorner", SGToggle).CornerRadius = UDim.new(1, 0)
local SGToggleStroke = Instance.new("UIStroke", SGToggle)
SGToggleStroke.Color        = Color3.fromRGB(60, 60, 60)
SGToggleStroke.Thickness    = 1
SGToggleStroke.Transparency = 0.2

local SGThumb = Instance.new("Frame", SGToggle)
SGThumb.Size             = UDim2.new(0, 12, 0, 12)
SGThumb.Position         = UDim2.new(0, 3, 0.5, -6)
SGThumb.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
SGThumb.BorderSizePixel  = 0
SGThumb.ZIndex           = 7
Instance.new("UICorner", SGThumb).CornerRadius = UDim.new(1, 0)

-- Wire up the forward-declared reference to the main panel card status
autoBombStatusVal = BombStatusVal

-- =====================================================
--  DISCORD POPUP  (modal overlay)
-- =====================================================

-- Dark backdrop
local PopupBackdrop = Instance.new("Frame", SG)
PopupBackdrop.Size                   = UDim2.new(1, 0, 1, 0)
PopupBackdrop.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
PopupBackdrop.BackgroundTransparency = 0.5
PopupBackdrop.BorderSizePixel        = 0
PopupBackdrop.ZIndex                 = 200
PopupBackdrop.Visible                = false

-- Popup card
local Popup = Instance.new("Frame", SG)
Popup.Name             = "DiscordPopup"
Popup.Size             = UDim2.new(0, 220, 0, 148)
Popup.AnchorPoint      = Vector2.new(0.5, 0.5)
Popup.Position         = UDim2.new(0.5, 0, 0.5, 0)
Popup.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
Popup.BorderSizePixel  = 0
Popup.ZIndex           = 201
Popup.Visible          = false
Instance.new("UICorner", Popup).CornerRadius = UDim.new(0, 14)

local PopupStroke = Instance.new("UIStroke", Popup)
PopupStroke.Color        = Color3.fromRGB(55, 55, 55)
PopupStroke.Thickness    = 1.5
PopupStroke.Transparency = 0.2

-- Top accent line
local PopupAccent = Instance.new("Frame", Popup)
PopupAccent.Size             = UDim2.new(0.5, 0, 0, 2)
PopupAccent.Position         = UDim2.new(0.25, 0, 0, 0)
PopupAccent.BackgroundColor3 = Color3.fromRGB(220, 220, 220)
PopupAccent.BorderSizePixel  = 0
PopupAccent.ZIndex           = 202
Instance.new("UICorner", PopupAccent).CornerRadius = UDim.new(0, 2)

-- Shadow
local PopupShad = Instance.new("ImageLabel", Popup)
PopupShad.AnchorPoint            = Vector2.new(0.5, 0.5)
PopupShad.BackgroundTransparency = 1
PopupShad.Position               = UDim2.new(0.5, 0, 0.5, 8)
PopupShad.Size                   = UDim2.new(1, 50, 1, 50)
PopupShad.ZIndex                 = 200
PopupShad.Image                  = "rbxassetid://6014261993"
PopupShad.ImageColor3            = Color3.fromRGB(0, 0, 0)
PopupShad.ImageTransparency      = 0.4
PopupShad.ScaleType              = Enum.ScaleType.Slice
PopupShad.SliceCenter            = Rect.new(49, 49, 450, 450)

-- Title "Please"
local PopupTitle = Instance.new("TextLabel", Popup)
PopupTitle.Size               = UDim2.new(1, -24, 0, 28)
PopupTitle.Position           = UDim2.new(0, 12, 0, 12)
PopupTitle.BackgroundTransparency = 1
PopupTitle.Text               = "Please"
PopupTitle.TextColor3         = Color3.fromRGB(230, 230, 230)
PopupTitle.TextSize           = 15
PopupTitle.Font               = Enum.Font.GothamBold
PopupTitle.TextXAlignment     = Enum.TextXAlignment.Center
PopupTitle.ZIndex             = 202

-- Divider under title
local PopupDiv = Instance.new("Frame", Popup)
PopupDiv.Size             = UDim2.new(1, -24, 0, 1)
PopupDiv.Position         = UDim2.new(0, 12, 0, 42)
PopupDiv.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
PopupDiv.BorderSizePixel  = 0
PopupDiv.ZIndex           = 202

-- Body text
local PopupMsg = Instance.new("TextLabel", Popup)
PopupMsg.Size               = UDim2.new(1, -24, 0, 62)
PopupMsg.Position           = UDim2.new(0, 12, 0, 50)
PopupMsg.BackgroundTransparency = 1
PopupMsg.Text               = "Please Join Our Discord Server If you Copied it So You Can Get Notified About updates and new scripts"
PopupMsg.TextColor3         = Color3.fromRGB(150, 150, 150)
PopupMsg.TextSize           = 9
PopupMsg.Font               = Enum.Font.Gotham
PopupMsg.TextXAlignment     = Enum.TextXAlignment.Center
PopupMsg.TextYAlignment     = Enum.TextYAlignment.Top
PopupMsg.TextWrapped        = true
PopupMsg.ZIndex             = 202

-- Okay button
local PopupOkBtn = Instance.new("TextButton", Popup)
PopupOkBtn.Size             = UDim2.new(1, -24, 0, 28)
PopupOkBtn.Position         = UDim2.new(0, 12, 1, -38)
PopupOkBtn.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
PopupOkBtn.Text             = ""
PopupOkBtn.BorderSizePixel  = 0
PopupOkBtn.AutoButtonColor  = false
PopupOkBtn.ZIndex           = 202
Instance.new("UICorner", PopupOkBtn).CornerRadius = UDim.new(0, 8)

local PopupOkStroke = Instance.new("UIStroke", PopupOkBtn)
PopupOkStroke.Color        = Color3.fromRGB(60, 60, 60)
PopupOkStroke.Thickness    = 1
PopupOkStroke.Transparency = 0.3

local PopupOkText = Instance.new("TextLabel", PopupOkBtn)
PopupOkText.Size               = UDim2.new(1, 0, 1, 0)
PopupOkText.BackgroundTransparency = 1
PopupOkText.Text               = "Okay"
PopupOkText.TextColor3         = Color3.fromRGB(190, 190, 190)
PopupOkText.TextSize           = 11
PopupOkText.Font               = Enum.Font.GothamBold
PopupOkText.ZIndex             = 203

local function showPopup()
	PopupBackdrop.Visible = true
	Popup.Visible         = true
	Popup.Size            = UDim2.new(0, 0, 0, 0)
	TweenService:Create(Popup, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0, 220, 0, 148) }):Play()
end

local function hidePopup()
	TweenService:Create(Popup, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
		{ Size = UDim2.new(0, 0, 0, 0) }):Play()
	task.delay(0.2, function()
		Popup.Visible         = false
		PopupBackdrop.Visible = false
	end)
end

PopupOkBtn.MouseButton1Click:Connect(hidePopup)
PopupOkBtn.MouseEnter:Connect(function()
	TweenService:Create(PopupOkBtn, TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(30, 30, 30) }):Play()
end)
PopupOkBtn.MouseLeave:Connect(function()
	TweenService:Create(PopupOkBtn, TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }):Play()
end)

-- =====================================================
--  SHOW / HIDE BUTTON  (right screen edge)
-- =====================================================

local ShowBtn = Instance.new("TextButton", SG)
ShowBtn.Size             = UDim2.new(0, 24, 0, 46)
ShowBtn.Position         = UDim2.new(1, -24, 0.5, -23)
ShowBtn.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
ShowBtn.Text             = ""
ShowBtn.BorderSizePixel  = 0
ShowBtn.AutoButtonColor  = false
ShowBtn.ZIndex           = 50
Instance.new("UICorner", ShowBtn).CornerRadius = UDim.new(0, 7)
local ShowStroke = Instance.new("UIStroke", ShowBtn)
ShowStroke.Color        = Color3.fromRGB(230, 230, 230)
ShowStroke.Thickness    = 1
ShowStroke.Transparency = 0.55
local ArrowLbl = Instance.new("TextLabel", ShowBtn)
ArrowLbl.Size               = UDim2.new(1, 0, 1, 0)
ArrowLbl.BackgroundTransparency = 1
ArrowLbl.Text               = "<"
ArrowLbl.TextColor3         = Color3.fromRGB(230, 230, 230)
ArrowLbl.TextSize           = 18
ArrowLbl.Font               = Enum.Font.GothamBold
ArrowLbl.ZIndex             = 51

-- =====================================================
--  MINI CIRCLE
-- =====================================================

local Mini = Instance.new("TextButton", SG)
Mini.Name             = "MiniCircle"
Mini.Size             = UDim2.new(0, 56, 0, 56)
Mini.Position         = UDim2.new(0, 28, 0.5, 10)
Mini.AnchorPoint      = Vector2.new(0.5, 0.5)
Mini.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
Mini.Text             = ""
Mini.BorderSizePixel  = 0
Mini.AutoButtonColor  = false
Mini.Visible          = false
Mini.Active           = true
Mini.Draggable        = true
Mini.ZIndex           = 60
Instance.new("UICorner", Mini).CornerRadius = UDim.new(1, 0)

local MiniGlow = Instance.new("UIStroke", Mini)
MiniGlow.Color        = Color3.fromRGB(230, 230, 230)
MiniGlow.Thickness    = 2
MiniGlow.Transparency = 0.55

local MiniShadFrame = Instance.new("Frame", SG)
MiniShadFrame.Size             = UDim2.new(0, 84, 0, 84)
MiniShadFrame.AnchorPoint      = Vector2.new(0.5, 0.5)
MiniShadFrame.Position         = UDim2.new(0, 28, 0.5, 14)
MiniShadFrame.BackgroundTransparency = 1
MiniShadFrame.ZIndex           = 58
MiniShadFrame.Visible          = false
local MiniShad = Instance.new("ImageLabel", MiniShadFrame)
MiniShad.AnchorPoint           = Vector2.new(0.5, 0.5)
MiniShad.BackgroundTransparency = 1
MiniShad.Position              = UDim2.new(0.5, 0, 0.5, 0)
MiniShad.Size                  = UDim2.new(1, 0, 1, 0)
MiniShad.ZIndex                = 58
MiniShad.Image                 = "rbxassetid://6014261993"
MiniShad.ImageColor3           = Color3.fromRGB(0, 0, 0)
MiniShad.ImageTransparency     = 0.42
MiniShad.ScaleType             = Enum.ScaleType.Slice
MiniShad.SliceCenter           = Rect.new(49, 49, 450, 450)

local MiniInnerRing = Instance.new("Frame", Mini)
MiniInnerRing.Size             = UDim2.new(0, 44, 0, 44)
MiniInnerRing.Position         = UDim2.new(0.5, -22, 0.5, -22)
MiniInnerRing.BackgroundTransparency = 1
MiniInnerRing.ZIndex           = 61
Instance.new("UICorner", MiniInnerRing).CornerRadius = UDim.new(1, 0)
local MiniInnerStroke = Instance.new("UIStroke", MiniInnerRing)
MiniInnerStroke.Color        = Color3.fromRGB(230, 230, 230)
MiniInnerStroke.Thickness    = 1
MiniInnerStroke.Transparency = 0.78

local MiniLbl = Instance.new("TextLabel", Mini)
MiniLbl.Size               = UDim2.new(1, 0, 0.5, 2)
MiniLbl.Position           = UDim2.new(0, 0, 0.5, -1)
MiniLbl.BackgroundTransparency = 1
MiniLbl.Text               = "OFF"
MiniLbl.TextColor3         = Color3.fromRGB(105, 96, 148)
MiniLbl.TextSize           = 11
MiniLbl.Font               = Enum.Font.GothamBold
MiniLbl.ZIndex             = 63

local MiniDot = Instance.new("Frame", Mini)
MiniDot.Size             = UDim2.new(0, 5, 0, 5)
MiniDot.Position         = UDim2.new(0.5, -2, 0, 10)
MiniDot.BackgroundColor3 = Color3.fromRGB(72, 56, 98)
MiniDot.BorderSizePixel  = 0
MiniDot.ZIndex           = 63
Instance.new("UICorner", MiniDot).CornerRadius = UDim.new(1, 0)

local MiniHoldBar = Instance.new("Frame", Mini)
MiniHoldBar.Size             = UDim2.new(0, 0, 0, 2)
MiniHoldBar.Position         = UDim2.new(0.5, 0, 1, -8)
MiniHoldBar.AnchorPoint      = Vector2.new(0.5, 0)
MiniHoldBar.BackgroundColor3 = Color3.fromRGB(230, 230, 230)
MiniHoldBar.BorderSizePixel  = 0
MiniHoldBar.ZIndex           = 65
Instance.new("UICorner", MiniHoldBar).CornerRadius = UDim.new(0, 1)

local LockIcon = Instance.new("TextLabel", Mini)
LockIcon.Size               = UDim2.new(1, 0, 0, 12)
LockIcon.Position           = UDim2.new(0, 0, 0, 7)
LockIcon.BackgroundTransparency = 1
LockIcon.Text               = "[L]"
LockIcon.TextSize           = 9
LockIcon.Font               = Enum.Font.GothamBold
LockIcon.ZIndex             = 64
LockIcon.Visible            = false

-- =====================================================
--  ANIMATIONS
-- =====================================================

local pulseRunning = false

local function doPulse()
	if not tracking or not pulseRunning then return end
	PulseDot.BackgroundColor3 = Color3.fromRGB(230, 230, 230)
	PulseRing.Size     = UDim2.new(0, 7, 0, 7)
	PulseRing.Position = UDim2.new(0, 14, 0.5, -3)
	PulseStroke.Transparency = 0.12
	tw(PulseRing, { Size = UDim2.new(0, 20, 0, 20) }, 0.55, Enum.EasingStyle.Quad)
	tw(PulseRing, { Position = UDim2.new(0, 7.5, 0.5, -10) }, 0.55, Enum.EasingStyle.Quad)
	tw(PulseStroke, { Transparency = 1 }, 0.55, Enum.EasingStyle.Quad)
	task.delay(0.65, function()
		if pulseRunning and tracking then doPulse() end
	end)
end

local function doShimmer()
	-- Shimmer sweeps inside BtnClip only - won't bleed outside
	BtnShimmer.Position = UDim2.new(-0.6, 0, 0, 0)
	tw(BtnShimmer, { Position = UDim2.new(1.3, 0, 0, 0) }, 0.48, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
end

local function doMiniEntrance()
	Mini.Rotation = -25
	Mini.Size     = UDim2.new(0, 4, 0, 4)
	tw(Mini, { Size = UDim2.new(0, 56, 0, 56), Rotation = 0 }, 0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

local miniGlowConn = nil
local function startMiniGlow()
	if miniGlowConn then return end
	miniGlowConn = RunService.Heartbeat:Connect(function() end) -- keep-alive stub
	local function loop()
		if not tracking or not miniVisible then
			if miniGlowConn then miniGlowConn:Disconnect(); miniGlowConn = nil end
			return
		end
		tw(MiniGlow, { Transparency = 0.05, Thickness = 2.8 }, 0.5, Enum.EasingStyle.Sine)
		task.delay(0.54, function()
			if not tracking or not miniVisible then
				if miniGlowConn then miniGlowConn:Disconnect(); miniGlowConn = nil end
				return
			end
			tw(MiniGlow, { Transparency = 0.6, Thickness = 1.6 }, 0.5, Enum.EasingStyle.Sine)
			task.delay(0.54, loop)
		end)
	end
	loop()
end

local function stopMiniGlow()
	if miniGlowConn then miniGlowConn:Disconnect(); miniGlowConn = nil end
	tw(MiniGlow, { Transparency = 0.55, Thickness = 2 }, 0.3)
end

-- (Line ESP toggle UI removed - ESP row deleted from main panel)

-- =====================================================
--  LOCK MINI
-- =====================================================

local function applyMiniLock()
	Mini.Draggable   = not miniLocked
	LockIcon.Visible = miniLocked
	if miniLocked then
		tw(LockToggle,      { BackgroundColor3 = Color3.fromRGB(40, 40, 40) }, 0.18)
		tw(LockThumb,       { Position = UDim2.new(1, -15, 0.5, -6), BackgroundColor3 = Color3.fromRGB(220, 220, 220) }, 0.2, Enum.EasingStyle.Back)
		tw(LockToggleStroke,{ Color = Color3.fromRGB(230, 230, 230) }, 0.18)
	else
		tw(LockToggle,      { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }, 0.18)
		tw(LockThumb,       { Position = UDim2.new(0, 3, 0.5, -6), BackgroundColor3 = Color3.fromRGB(100, 100, 100) }, 0.2, Enum.EasingStyle.Back)
		tw(LockToggleStroke,{ Color = Color3.fromRGB(60, 60, 60) }, 0.18)
	end
end

LockToggle.MouseButton1Click:Connect(function()
	miniLocked = not miniLocked
	applyMiniLock()
end)

-- -- Double Jump toggle handler ------------------------
local function applyDJToggle()
	if doubleJumpOn then
		tw(DJToggle,      { BackgroundColor3 = Color3.fromRGB(40, 40, 40) }, 0.18)
		tw(DJThumb,       { Position = UDim2.new(1, -15, 0.5, -6), BackgroundColor3 = Color3.fromRGB(220, 220, 220) }, 0.2, Enum.EasingStyle.Back)
		tw(DJToggleStroke,{ Color = Color3.fromRGB(230, 230, 230) }, 0.18)
		tw(DJDot,         { BackgroundColor3 = Color3.fromRGB(230, 230, 230) }, 0.2)
		tw(DJLabel,       { TextColor3 = Color3.fromRGB(220, 220, 220) }, 0.2)
		tw(DJRowStroke,   { Color = Color3.fromRGB(50, 50, 50), Transparency = 0.08 }, 0.2)
		startDoubleJump()
	else
		tw(DJToggle,      { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }, 0.18)
		tw(DJThumb,       { Position = UDim2.new(0, 3, 0.5, -6), BackgroundColor3 = Color3.fromRGB(100, 100, 100) }, 0.2, Enum.EasingStyle.Back)
		tw(DJToggleStroke,{ Color = Color3.fromRGB(60, 60, 60) }, 0.18)
		tw(DJDot,         { BackgroundColor3 = Color3.fromRGB(55, 55, 55) }, 0.2)
		tw(DJLabel,       { TextColor3 = Color3.fromRGB(175, 175, 175) }, 0.2)
		tw(DJRowStroke,   { Color = Color3.fromRGB(40, 40, 40), Transparency = 0.25 }, 0.2)
		stopDoubleJump()
	end
end

DJToggle.MouseButton1Click:Connect(function()
	doubleJumpOn = not doubleJumpOn
	applyDJToggle()
end)
DJToggle.MouseEnter:Connect(function()
	tw(DJRow, { BackgroundColor3 = Color3.fromRGB(20, 20, 20) }, 0.12)
end)
DJToggle.MouseLeave:Connect(function()
	tw(DJRow, { BackgroundColor3 = Color3.fromRGB(12, 12, 12) }, 0.12)
end)

DJPowerBox.FocusLost:Connect(function()
	local val = tonumber(DJPowerBox.Text)
	if val then
		val = math.clamp(math.floor(val * 100 + 0.5) / 100, 0.3, 1.0)
		DOUBLE_JUMP_POWER = val
		DJPowerBox.Text = tostring(DOUBLE_JUMP_POWER)
		tw(DJPowerBoxStroke, { Color = Color3.fromRGB(180, 180, 180) }, 0.12)
		task.delay(0.6, function()
			tw(DJPowerBoxStroke, { Color = Color3.fromRGB(55, 55, 55) }, 0.3)
		end)
	else
		DJPowerBox.Text = tostring(DOUBLE_JUMP_POWER)
		tw(DJPowerBoxStroke, { Color = Color3.fromRGB(230, 230, 230) }, 0.12)
		task.delay(0.6, function()
			tw(DJPowerBoxStroke, { Color = Color3.fromRGB(55, 55, 55) }, 0.3)
		end)
	end
end)

-- -- Auto Get Bomb toggle handler ---------------------
local BombRowStroke = BombCardStroke  -- alias for handler reuse

local function applyBombToggle()
	if autoBomb then
		tw(BombToggle,      { BackgroundColor3 = Color3.fromRGB(40, 40, 40) }, 0.18)
		tw(BombThumb,       { Position = UDim2.new(1, -15, 0.5, -6), BackgroundColor3 = Color3.fromRGB(220, 220, 220) }, 0.2, Enum.EasingStyle.Back)
		tw(BombToggleStroke,{ Color = Color3.fromRGB(230, 230, 230) }, 0.18)
		tw(BombDot,         { BackgroundColor3 = Color3.fromRGB(230, 230, 230) }, 0.2)
		tw(BombLabel,       { TextColor3 = Color3.fromRGB(220, 220, 220) }, 0.2)
		tw(BombCardStroke,  { Color = Color3.fromRGB(80, 80, 80), Transparency = 0.1 }, 0.2)
		startAutoBomb()
	else
		tw(BombToggle,      { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }, 0.18)
		tw(BombThumb,       { Position = UDim2.new(0, 3, 0.5, -6), BackgroundColor3 = Color3.fromRGB(100, 100, 100) }, 0.2, Enum.EasingStyle.Back)
		tw(BombToggleStroke,{ Color = Color3.fromRGB(60, 60, 60) }, 0.18)
		tw(BombDot,         { BackgroundColor3 = Color3.fromRGB(55, 55, 55) }, 0.2)
		tw(BombLabel,       { TextColor3 = Color3.fromRGB(175, 175, 175) }, 0.2)
		tw(BombCardStroke,  { Color = Color3.fromRGB(50, 50, 50), Transparency = 0.3 }, 0.2)
		stopAutoBomb()
	end
end

BombToggle.MouseButton1Click:Connect(function()
	autoBomb = not autoBomb
	applyBombToggle()
end)

BombCountBox.FocusLost:Connect(function()
	local val = tonumber(BombCountBox.Text)
	if val and val > 0 then
		AUTOBOMB_COUNTDOWN = math.floor(val)
		BombCountBox.Text = tostring(AUTOBOMB_COUNTDOWN)
		tw(BombCountBoxStroke, { Color = Color3.fromRGB(180, 180, 180) }, 0.12)
		task.delay(0.6, function() tw(BombCountBoxStroke, { Color = Color3.fromRGB(55, 55, 55) }, 0.3) end)
	else
		BombCountBox.Text = tostring(AUTOBOMB_COUNTDOWN)
		tw(BombCountBoxStroke, { Color = Color3.fromRGB(200, 60, 60) }, 0.12)
		task.delay(0.6, function() tw(BombCountBoxStroke, { Color = Color3.fromRGB(55, 55, 55) }, 0.3) end)
	end
end)

BombStudsBox.FocusLost:Connect(function()
	local val = tonumber(BombStudsBox.Text)
	if val then
		val = math.clamp(math.floor(val), 1, 100)
		AUTOBOMB_STUDS = val
		BombStudsBox.Text = tostring(AUTOBOMB_STUDS)
		tw(BombStudsBoxStroke, { Color = Color3.fromRGB(180, 180, 180) }, 0.12)
		task.delay(0.6, function() tw(BombStudsBoxStroke, { Color = Color3.fromRGB(55, 55, 55) }, 0.3) end)
	else
		BombStudsBox.Text = tostring(AUTOBOMB_STUDS)
		tw(BombStudsBoxStroke, { Color = Color3.fromRGB(200, 60, 60) }, 0.12)
		task.delay(0.6, function() tw(BombStudsBoxStroke, { Color = Color3.fromRGB(55, 55, 55) }, 0.3) end)
	end
end)

-- =====================================================
-- Discord button
DiscordBtn.MouseButton1Click:Connect(function()
	setclipboard("https://discord.gg/np4JVBYH6x")
	-- Flash COPIED feedback
	DiscordCopyLbl.Text       = "COPIED!"
	DiscordCopyLbl.TextColor3 = Color3.fromRGB(210, 210, 210)
	TweenService:Create(DiscordStroke, TweenInfo.new(0.12), { Color = Color3.fromRGB(160, 160, 160), Transparency = 0.1 }):Play()
	task.delay(1.5, function()
		DiscordCopyLbl.Text       = "COPY"
		DiscordCopyLbl.TextColor3 = Color3.fromRGB(80, 80, 80)
		TweenService:Create(DiscordStroke, TweenInfo.new(0.3), { Color = Color3.fromRGB(55, 55, 55), Transparency = 0.3 }):Play()
	end)
	-- Show popup
	showPopup()
end)
DiscordBtn.MouseEnter:Connect(function()
	TweenService:Create(DiscordBtn,    TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }):Play()
	TweenService:Create(DiscordStroke, TweenInfo.new(0.12), { Transparency = 0.1 }):Play()
end)
DiscordBtn.MouseLeave:Connect(function()
	TweenService:Create(DiscordBtn,    TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(16, 16, 16) }):Play()
	TweenService:Create(DiscordStroke, TweenInfo.new(0.12), { Transparency = 0.3 }):Play()
end)

-- =====================================================
--  SETTINGS TAB NAVIGATION
-- =====================================================

local function openSettings()
	onSettings = true
	tw(TabContainer,    { Position = UDim2.new(-1, 0, 0, 45) }, 0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	tw(SettingsBtn,     { TextColor3 = Color3.fromRGB(230, 230, 230) }, 0.15)
	tw(SettingsBtnStroke,{ Color = Color3.fromRGB(230, 230, 230) }, 0.15)
end

local function closeSettings()
	onSettings = false
	tw(TabContainer,    { Position = UDim2.new(0, 0, 0, 45) }, 0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	tw(SettingsBtn,     { TextColor3 = Color3.fromRGB(130, 130, 130) }, 0.15)
	tw(SettingsBtnStroke,{ Color = Color3.fromRGB(60, 60, 60) }, 0.15)
end

SettingsBtn.MouseButton1Click:Connect(function()
	if onSettings then closeSettings() else openSettings() end
end)
SettingsBtn.MouseEnter:Connect(function()
	tw(SettingsBtn, { BackgroundColor3 = Color3.fromRGB(30, 30, 30) }, 0.12)
end)
SettingsBtn.MouseLeave:Connect(function()
	tw(SettingsBtn, { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }, 0.12)
end)
BackBtn.MouseButton1Click:Connect(function() closeSettings() end)
BackBtn.MouseEnter:Connect(function()
	tw(BackBtn, { BackgroundColor3 = Color3.fromRGB(24, 24, 24) }, 0.12)
end)
BackBtn.MouseLeave:Connect(function()
	tw(BackBtn, { BackgroundColor3 = Color3.fromRGB(18, 18, 18) }, 0.12)
end)

-- =====================================================
--  SHOW / HIDE MAIN WINDOW
-- =====================================================

local WIN_Y = -(WIN_H / 2)

local function setMainVisible(visible)
	mainVisible = visible
	if visible then
		Win.Visible       = true
		ShadFrame.Visible = true
		tw(Win,       { Position = UDim2.new(0, 28, 0.5, WIN_Y) }, 0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		tw(ShadFrame, { Position = UDim2.new(0, 10, 0.5, WIN_Y - 18) }, 0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		ArrowLbl.Text = "<"
	else
		tw(Win,       { Position = UDim2.new(0, -270, 0.5, WIN_Y) }, 0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
		tw(ShadFrame, { Position = UDim2.new(0, -290, 0.5, WIN_Y - 18) }, 0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
		task.delay(0.25, function()
			if not mainVisible then Win.Visible = false; ShadFrame.Visible = false end
		end)
		ArrowLbl.Text = ">"
	end
end

ShowBtn.MouseButton1Click:Connect(function()
	setMainVisible(not mainVisible)
end)
ShowBtn.MouseEnter:Connect(function()
	tw(ShowBtn,   { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }, 0.12)
	tw(ShowStroke,{ Transparency = 0.2 }, 0.12)
end)
ShowBtn.MouseLeave:Connect(function()
	tw(ShowBtn,   { BackgroundColor3 = Color3.fromRGB(12, 12, 12) }, 0.12)
	tw(ShowStroke,{ Transparency = 0.55 }, 0.12)
end)

-- =====================================================
--  MINI CIRCLE SHOW / HIDE
-- =====================================================

local function syncMiniShadow()
	if not miniVisible then return end
	local ap = Mini.AbsolutePosition
	local as = Mini.AbsoluteSize
	MiniShadFrame.Position = UDim2.new(0, ap.X + as.X / 2, 0, ap.Y + as.Y / 2 + 5)
end

local function showMini()
	miniVisible = true
	Mini.Visible          = true
	MiniShadFrame.Visible = true
	local absPos = Win.AbsolutePosition
	Mini.Position          = UDim2.new(0, absPos.X + 120, 0.5, 10)
	MiniShadFrame.Position = UDim2.new(0, absPos.X + 120, 0.5, 15)
	doMiniEntrance()
	applyMiniLock()
	if tracking then startMiniGlow() end
end

local function hideMini()
	miniVisible = false
	stopMiniGlow()
	tw(Mini, { Size = UDim2.new(0, 0, 0, 0), Rotation = 20 }, 0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
	task.delay(0.25, function()
		if not miniVisible then
			Mini.Visible          = false
			MiniShadFrame.Visible = false
			Mini.Rotation         = 0
			Mini.Size             = UDim2.new(0, 56, 0, 56)
		end
	end)
end

-- =====================================================
--  UI UPDATE
-- =====================================================

local function updateMiniLabel()
	if tracking then
		MiniLbl.Text       = "ON"
		MiniLbl.TextColor3 = Color3.fromRGB(220, 220, 220)
		tw(MiniDot,        { BackgroundColor3 = Color3.fromRGB(220, 220, 220) }, 0.2)
		tw(MiniInnerStroke,{ Color = Color3.fromRGB(230, 230, 230), Transparency = 0.35 }, 0.2)
		tw(Mini,           { BackgroundColor3 = Color3.fromRGB(12, 12, 12) }, 0.2)
		if miniVisible then startMiniGlow() end
	else
		MiniLbl.Text       = "OFF"
		MiniLbl.TextColor3 = Color3.fromRGB(105, 96, 148)
		tw(MiniDot,        { BackgroundColor3 = Color3.fromRGB(72, 56, 98) }, 0.2)
		tw(MiniInnerStroke,{ Color = Color3.fromRGB(230, 230, 230), Transparency = 0.78 }, 0.2)
		tw(Mini,           { BackgroundColor3 = Color3.fromRGB(10, 10, 10) }, 0.2)
		stopMiniGlow()
	end
end

local function updateUI()
	if tracking then
		tw(Btn,      { BackgroundColor3 = Color3.fromRGB(40, 40, 40) })
		tw(BtnStroke,{ Color = Color3.fromRGB(230, 230, 230), Transparency = 0.05 })
		tw(BtnPill,  { BackgroundColor3 = Color3.fromRGB(230, 230, 230) })
		tw(BtnText,  { TextColor3 = Color3.fromRGB(215, 215, 215) })
		tw(WinStroke,{ Transparency = 0.16 })
		BtnText.Text = "DISABLE"
		if not localHasTool() then
			StatusVal.Text       = "NO TOOL"
			StatusVal.TextColor3 = Color3.fromRGB(200, 200, 200)
			TargetVal.Text       = "-"
		elseif currentTarget then
			StatusVal.Text       = "TRACKING"
			StatusVal.TextColor3 = Color3.fromRGB(180, 180, 180)
			TargetVal.Text       = currentTarget.Name
			TargetVal.TextColor3 = Color3.fromRGB(200, 200, 200)
		else
			StatusVal.Text       = "SCANNING"
			StatusVal.TextColor3 = Color3.fromRGB(160, 160, 160)
			TargetVal.Text       = "-"
		end
	else
		tw(Btn,      { BackgroundColor3 = Color3.fromRGB(18, 18, 18) })
		tw(BtnStroke,{ Color = Color3.fromRGB(50, 50, 50), Transparency = 0.35 })
		tw(BtnPill,  { BackgroundColor3 = Color3.fromRGB(60, 60, 60) })
		tw(BtnText,  { TextColor3 = Color3.fromRGB(145, 145, 145) })
		tw(WinStroke,{ Transparency = 0.62 })
		BtnText.Text         = "ENABLE"
		StatusVal.Text       = "IDLE"
		StatusVal.TextColor3 = Color3.fromRGB(80, 80, 80)
		TargetVal.Text       = "-"
		TargetVal.TextColor3 = Color3.fromRGB(180, 180, 180)
	end
	updateMiniLabel()
end

-- =====================================================
--  HOLD LOGIC
-- =====================================================

local function startHoldWatch(bar, onComplete)
	local startT = tick()
	return RunService.Heartbeat:Connect(function()
		local frac = math.min((tick() - startT) / HOLD_DURATION, 1)
		bar.Size = UDim2.new(frac, 0, 0, 2)
		if frac >= 1 then onComplete() end
	end)
end

-- Main button
local mainHoldConn  = nil
local mainHoldFired = false

Btn.MouseButton1Down:Connect(function()
	if mainHoldConn then mainHoldConn:Disconnect(); mainHoldConn = nil end
	mainHoldFired = false
	HoldBar.Size = UDim2.new(0, 0, 0, 2)
	mainHoldConn = startHoldWatch(HoldBar, function()
		if mainHoldConn then mainHoldConn:Disconnect(); mainHoldConn = nil end
		mainHoldFired = true
		HoldBar.Size = UDim2.new(0, 0, 0, 2)
		if miniVisible then hideMini() else showMini() end
	end)
end)

Btn.MouseButton1Up:Connect(function()
	if mainHoldConn then
		mainHoldConn:Disconnect(); mainHoldConn = nil
		tw(HoldBar, { Size = UDim2.new(0, 0, 0, 2) }, 0.12)
		if not mainHoldFired then
			tracking = not tracking
			if tracking then
				startTracking(); doShimmer()
				pulseRunning = true; doPulse()
			else
				stopTracking()
				pulseRunning = false
				PulseDot.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
			end
			updateUI()
		end
	end
end)

-- Mini button
local miniHoldConn  = nil
local miniHoldFired = false

Mini.MouseButton1Down:Connect(function()
	if miniHoldConn then miniHoldConn:Disconnect(); miniHoldConn = nil end
	miniHoldFired = false
	MiniHoldBar.Size = UDim2.new(0, 0, 0, 2)
	miniHoldConn = startHoldWatch(MiniHoldBar, function()
		if miniHoldConn then miniHoldConn:Disconnect(); miniHoldConn = nil end
		miniHoldFired = true
		MiniHoldBar.Size = UDim2.new(0, 0, 0, 2)
		hideMini()
	end)
end)

Mini.MouseButton1Up:Connect(function()
	if miniHoldConn then
		miniHoldConn:Disconnect(); miniHoldConn = nil
		tw(MiniHoldBar, { Size = UDim2.new(0, 0, 0, 2) }, 0.12)
		if not miniHoldFired then
			tracking = not tracking
			if tracking then
				startTracking()
				pulseRunning = true; doPulse()
			else
				stopTracking()
				pulseRunning = false
				PulseDot.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
			end
			updateUI()
		end
	end
end)

-- Hover effects
Btn.MouseEnter:Connect(function()
	tw(Btn, { BackgroundColor3 = tracking and Color3.fromRGB(40, 40, 40) or Color3.fromRGB(22, 22, 22) }, 0.12)
end)
Btn.MouseLeave:Connect(function()
	if mainHoldConn then mainHoldConn:Disconnect(); mainHoldConn = nil end
	tw(HoldBar, { Size = UDim2.new(0, 0, 0, 2) }, 0.1)
	tw(Btn, { BackgroundColor3 = tracking and Color3.fromRGB(40, 40, 40) or Color3.fromRGB(18, 18, 18) }, 0.12)
end)

Mini.MouseEnter:Connect(function()
	tw(Mini, { Size = UDim2.new(0, 62, 0, 62) }, 0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end)
Mini.MouseLeave:Connect(function()
	if miniHoldConn then miniHoldConn:Disconnect(); miniHoldConn = nil end
	tw(MiniHoldBar, { Size = UDim2.new(0, 0, 0, 2) }, 0.1)
	tw(Mini, { Size = UDim2.new(0, 56, 0, 56) }, 0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
end)

-- =====================================================
--  STATUS GUI  (separate draggable overlay)
-- =====================================================

local StatusWin = Instance.new("Frame", SG)
StatusWin.Name             = "StatusGui"
StatusWin.Size             = UDim2.new(0, 180, 0, 112)
StatusWin.Position         = UDim2.new(1, -208, 0, 60)
StatusWin.BackgroundColor3 = Color3.fromRGB(8, 8, 8)
StatusWin.BorderSizePixel  = 0
StatusWin.Active           = true
StatusWin.Draggable        = true
StatusWin.Visible          = false
StatusWin.ZIndex           = 80
Instance.new("UICorner", StatusWin).CornerRadius = UDim.new(0, 12)
local StatusWinStroke = Instance.new("UIStroke", StatusWin)
StatusWinStroke.Color           = Color3.fromRGB(50, 50, 50)
StatusWinStroke.Thickness       = 1
StatusWinStroke.Transparency    = 0.3
StatusWinStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

-- Top accent
local SWAccent = Instance.new("Frame", StatusWin)
SWAccent.Size             = UDim2.new(0.4, 0, 0, 2)
SWAccent.Position         = UDim2.new(0.3, 0, 0, 0)
SWAccent.BackgroundColor3 = Color3.fromRGB(200, 200, 200)
SWAccent.BorderSizePixel  = 0
SWAccent.ZIndex           = 82
Instance.new("UICorner", SWAccent).CornerRadius = UDim.new(0, 2)

-- Header
local SWHdr = Instance.new("Frame", StatusWin)
SWHdr.Size             = UDim2.new(1, 0, 0, 28)
SWHdr.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
SWHdr.BorderSizePixel  = 0
SWHdr.ZIndex           = 81
Instance.new("UICorner", SWHdr).CornerRadius = UDim.new(0, 12)

-- Extend header to cover bottom corners
local SWHdrFill = Instance.new("Frame", StatusWin)
SWHdrFill.Size             = UDim2.new(1, 0, 0, 14)
SWHdrFill.Position         = UDim2.new(0, 0, 0, 14)
SWHdrFill.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
SWHdrFill.BorderSizePixel  = 0
SWHdrFill.ZIndex           = 81

-- Title as direct child of StatusWin so nothing clips it
local SWTitle = Instance.new("TextLabel", StatusWin)
SWTitle.Size               = UDim2.new(1, -12, 0, 28)
SWTitle.Position           = UDim2.new(0, 10, 0, 0)
SWTitle.BackgroundTransparency = 1
SWTitle.Text               = "STATUS"
SWTitle.TextColor3         = Color3.fromRGB(170, 170, 170)
SWTitle.TextSize           = 9
SWTitle.Font               = Enum.Font.GothamBold
SWTitle.TextXAlignment     = Enum.TextXAlignment.Left
SWTitle.ZIndex             = 84

-- Divider
local SWDiv = Instance.new("Frame", StatusWin)
SWDiv.Size             = UDim2.new(1, -16, 0, 1)
SWDiv.Position         = UDim2.new(0, 8, 0, 28)
SWDiv.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
SWDiv.BorderSizePixel  = 0
SWDiv.ZIndex           = 82

-- Row helper
local function makeSWRow(labelTxt, yOff)
	local k = Instance.new("TextLabel", StatusWin)
	k.Size               = UDim2.new(0, 58, 0, 14)
	k.Position           = UDim2.new(0, 10, 0, yOff)
	k.BackgroundTransparency = 1
	k.Text               = labelTxt
	k.TextColor3         = Color3.fromRGB(65, 65, 65)
	k.TextSize           = 9
	k.Font               = Enum.Font.GothamBold
	k.TextXAlignment     = Enum.TextXAlignment.Left
	k.ZIndex             = 83
	local v = Instance.new("TextLabel", StatusWin)
	v.Size               = UDim2.new(1, -72, 0, 14)
	v.Position           = UDim2.new(0, 68, 0, yOff)
	v.BackgroundTransparency = 1
	v.Text               = "-"
	v.TextColor3         = Color3.fromRGB(180, 180, 180)
	v.TextSize           = 9
	v.Font               = Enum.Font.GothamBold
	v.TextXAlignment     = Enum.TextXAlignment.Left
	v.ZIndex             = 83
	return v
end

local SW_TrackVal = makeSWRow("TRACK",  34)
local SW_BombVal  = makeSWRow("BOMB",   50)
local SW_FpsVal   = makeSWRow("FPS",    68)
local SW_PingVal  = makeSWRow("PING",   84)

-- FPS / Ping tracking
local fpsCounter   = 0
local fpsLast      = tick()
local fpsDisplay   = 0

local function updateStatusGui()
	if not statusGuiOn then return end

	-- Track
	if tracking then
		if not localHasTool() then
			SW_TrackVal.Text       = "NO BOMB"
			SW_TrackVal.TextColor3 = Color3.fromRGB(200, 130, 60)
		elseif currentTarget then
			SW_TrackVal.Text       = currentTarget.Name
			SW_TrackVal.TextColor3 = Color3.fromRGB(160, 210, 160)
		else
			SW_TrackVal.Text       = "SCANNING"
			SW_TrackVal.TextColor3 = Color3.fromRGB(130, 160, 210)
		end
	else
		SW_TrackVal.Text       = "OFF"
		SW_TrackVal.TextColor3 = Color3.fromRGB(80, 80, 80)
	end

	-- Bomb
	if autoBomb then
		SW_BombVal.Text       = autoBombStatusVal and autoBombStatusVal.Text or "ON"
		SW_BombVal.TextColor3 = Color3.fromRGB(180, 180, 180)
	else
		SW_BombVal.Text       = "OFF"
		SW_BombVal.TextColor3 = Color3.fromRGB(80, 80, 80)
	end

	-- FPS
	fpsCounter = fpsCounter + 1
	local now = tick()
	if now - fpsLast >= 1 then
		fpsDisplay = fpsCounter
		fpsCounter = 0
		fpsLast    = now
	end
	local fps = fpsDisplay
	SW_FpsVal.Text       = tostring(fps)
	SW_FpsVal.TextColor3 = fps >= 55 and Color3.fromRGB(140, 210, 140)
		or fps >= 30 and Color3.fromRGB(210, 180, 80)
		or Color3.fromRGB(210, 80, 80)

	-- Ping
	local ok, ping = pcall(function()
		return math.floor(Players.LocalPlayer:GetNetworkPing() * 1000)
	end)
	if ok and ping then
		SW_PingVal.Text       = tostring(ping) .. " ms"
		SW_PingVal.TextColor3 = ping < 80  and Color3.fromRGB(140, 210, 140)
			or ping < 150 and Color3.fromRGB(210, 180, 80)
			or Color3.fromRGB(210, 80, 80)
	else
		SW_PingVal.Text       = "-"
		SW_PingVal.TextColor3 = Color3.fromRGB(80, 80, 80)
	end
end

-- Status Gui toggle handler
local function applyStatusGuiToggle()
	if statusGuiOn then
		tw(SGToggle,      { BackgroundColor3 = Color3.fromRGB(40, 40, 40) }, 0.18)
		tw(SGThumb,       { Position = UDim2.new(1, -15, 0.5, -6), BackgroundColor3 = Color3.fromRGB(220, 220, 220) }, 0.2, Enum.EasingStyle.Back)
		tw(SGToggleStroke,{ Color = Color3.fromRGB(230, 230, 230) }, 0.18)
		tw(SGDot,         { BackgroundColor3 = Color3.fromRGB(230, 230, 230) }, 0.2)
		tw(SGLabel,       { TextColor3 = Color3.fromRGB(220, 220, 220) }, 0.2)
		tw(SGRowStroke,   { Color = Color3.fromRGB(60, 60, 60), Transparency = 0.08 }, 0.2)
		StatusWin.Visible = true
	else
		tw(SGToggle,      { BackgroundColor3 = Color3.fromRGB(22, 22, 22) }, 0.18)
		tw(SGThumb,       { Position = UDim2.new(0, 3, 0.5, -6), BackgroundColor3 = Color3.fromRGB(100, 100, 100) }, 0.2, Enum.EasingStyle.Back)
		tw(SGToggleStroke,{ Color = Color3.fromRGB(60, 60, 60) }, 0.18)
		tw(SGDot,         { BackgroundColor3 = Color3.fromRGB(55, 55, 55) }, 0.2)
		tw(SGLabel,       { TextColor3 = Color3.fromRGB(175, 175, 175) }, 0.2)
		tw(SGRowStroke,   { Color = Color3.fromRGB(40, 40, 40), Transparency = 0.25 }, 0.2)
		StatusWin.Visible = false
	end
end

SGToggle.MouseButton1Click:Connect(function()
	statusGuiOn = not statusGuiOn
	applyStatusGuiToggle()
end)
SGToggle.MouseEnter:Connect(function()
	tw(SGRow, { BackgroundColor3 = Color3.fromRGB(20, 20, 20) }, 0.12)
end)
SGToggle.MouseLeave:Connect(function()
	tw(SGRow, { BackgroundColor3 = Color3.fromRGB(12, 12, 12) }, 0.12)
end)

-- =====================================================
--  LIVE LOOP
-- =====================================================

RunService.Heartbeat:Connect(function()
	if tracking then updateUI() end
	if miniVisible and not miniLocked then syncMiniShadow() end
	-- Keep shadow frame glued to the main window (fixes frozen shadow when dragged)
	if mainVisible then
		local ap = Win.AbsolutePosition
		local as = Win.AbsoluteSize
		ShadFrame.Position = UDim2.new(0, ap.X - 18, 0, ap.Y - 18)
		ShadFrame.Size     = UDim2.new(0, as.X + 36, 0, as.Y + 36)
	end
	updateStatusGui()
end)

-- =====================================================
--  INIT
-- =====================================================

SG.Enabled        = true
Win.Visible       = true
ShadFrame.Visible = true
updateUI()
