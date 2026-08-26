-- WoW Doom: a raycasting engine reimplemented against WoW's UI frame API.
-- This is NOT DOOM's code or WAD data (that couldn't run in the addon sandbox
-- at all - no FFI, no native code, no external processes). It's an original
-- Wolfenstein/DOOM-style raycaster: a hand-built maze, cast in Lua, drawn as a
-- row of flat-shaded vertical strips (WoW Textures), same as everything else
-- in this AddOns folder.
--
-- Performance approach (learned from how other "DOOM on constrained surfaces"
-- ports actually stay usable, e.g. the DOOM-on-Google-Sheets project explicitly
-- rendering low-res and only touching cells that changed):
--   1. Low column count (one Texture per screen column) instead of real pixel
--      resolution - this is the actual cost driver, not the ray math.
--   2. Each column's Texture is anchored ONCE, by its center, and never
--      re-anchored. Every frame we only ever call SetHeight/SetVertexColor,
--      and only when the value actually changed since last frame.
--   3. Flat-shaded walls (distance + side shading), no per-pixel texturing.

-- ===== Config =====
local FRAME_W, FRAME_H = 560, 470
local PLAY_W, PLAY_H   = 520, 340
local NUM_COLUMNS      = 72
local FOV              = math.rad(66)
local CELL             = 64          -- world units per map cell
local MAX_STEPS        = 40
local STEP_SIZE        = CELL / 4
local MAX_RENDER_DIST  = MAX_STEPS * STEP_SIZE
local MOVE_SPEED       = 130         -- world units / sec
local TURN_SPEED       = 2.6         -- radians / sec
local PLAYER_RADIUS    = 12

local cos, sin, floor, min, max = math.cos, math.sin, math.floor, math.min, math.max

-- ===== Map: a small hand-built maze. 1 = wall, 0 = open. Not derived from any WAD. =====
local MAP_ROWS = {
	"1111111111111111",
	"1000000000000001",
	"1011110111011101",
	"1010000100010001",
	"1010111101110101",
	"1000100000000101",
	"1110101111110101",
	"1000101000000101",
	"1011101011111101",
	"1000001010000001",
	"1011111010111101",
	"1111111111111111",
}
local MAP_W, MAP_H = #MAP_ROWS[1], #MAP_ROWS

local MAP = {}
for y = 1, MAP_H do
	MAP[y] = {}
	for x = 1, MAP_W do
		MAP[y][x] = tonumber(MAP_ROWS[y]:sub(x, x))
	end
end

local function IsWall(worldX, worldY)
	local cx = floor(worldX / CELL) + 1
	local cy = floor(worldY / CELL) + 1
	if cx < 1 or cy < 1 or cx > MAP_W or cy > MAP_H then return true end
	return MAP[cy][cx] == 1
end

-- ===== Player state =====
local playerX, playerY = (2 + 0.5) * CELL, (1 + 0.5) * CELL
local playerAngle = 0

local held = { forward = false, back = false, left = false, right = false }

-- ===== Frame skeleton (same chrome style as the rest of this AddOns folder) =====
local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

local frame = CreateFrame("Frame", "WoWDoomFrame", UIParent, backdropTemplate)
frame:SetSize(FRAME_W, FRAME_H)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
if frame.SetBackdrop then
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
end
frame:Hide()
tinsert(UISpecialFrames, "WoWDoomFrame")

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
title:SetPoint("TOP", 0, -16)
title:SetText("WoW Doom")

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -4, -4)

local helpText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
helpText:SetPoint("TOP", title, "BOTTOM", 0, -4)
helpText:SetText("WASD / Arrows to move + turn. Escape to close.")

-- Play area
local play = CreateFrame("Frame", nil, frame)
play:SetSize(PLAY_W, PLAY_H)
play:SetPoint("BOTTOM", 0, 20)
if play.SetClipsChildren then play:SetClipsChildren(true) end

-- Ceiling / floor: static, drawn once, never touched again.
local ceiling = play:CreateTexture(nil, "BACKGROUND")
ceiling:SetPoint("TOPLEFT")
ceiling:SetPoint("TOPRIGHT")
ceiling:SetHeight(PLAY_H / 2)
ceiling:SetColorTexture(0.22, 0.22, 0.26)

local floorTex = play:CreateTexture(nil, "BACKGROUND")
floorTex:SetPoint("BOTTOMLEFT")
floorTex:SetPoint("BOTTOMRIGHT")
floorTex:SetHeight(PLAY_H / 2)
floorTex:SetColorTexture(0.35, 0.32, 0.28)

-- ===== Column pool: created once, anchored once, never re-anchored. =====
local columns = {}
do
	local colW = PLAY_W / NUM_COLUMNS
	for i = 1, NUM_COLUMNS do
		local col = {}
		col.tex = play:CreateTexture(nil, "ARTWORK")
		col.tex:SetWidth(colW + 1) -- +1 avoids hairline seams between columns
		col.tex:SetColorTexture(1, 1, 1)
		col.tex:SetPoint("CENTER", play, "BOTTOMLEFT", (i - 0.5) * colW, PLAY_H / 2)
		col.tex:SetHeight(PLAY_H)
		col.lastH = PLAY_H
		col.lastShadeKey = nil
		columns[i] = col
	end
end

-- ===== Minimap (debug aid: cheap, drawn once except the player marker) =====
local MINI_SCALE = 4
local minimap = CreateFrame("Frame", nil, frame)
minimap:SetSize(MAP_W * MINI_SCALE, MAP_H * MINI_SCALE)
minimap:SetPoint("TOPLEFT", play, "TOPLEFT", 6, -6)
do
	local bg = minimap:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.5)
	for y = 1, MAP_H do
		for x = 1, MAP_W do
			if MAP[y][x] == 1 then
				local cell = minimap:CreateTexture(nil, "ARTWORK")
				cell:SetSize(MINI_SCALE, MINI_SCALE)
				cell:SetPoint("TOPLEFT", minimap, "TOPLEFT", (x - 1) * MINI_SCALE, -(y - 1) * MINI_SCALE)
				cell:SetColorTexture(0.7, 0.7, 0.75)
			end
		end
	end
end
local miniPlayer = minimap:CreateTexture(nil, "OVERLAY")
miniPlayer:SetSize(5, 5)
miniPlayer:SetColorTexture(1, 0.2, 0.2)

-- ===== Sprites: billboarded objects, depth-sorted against the wall z-buffer.
-- A handful of decorative "torches" for now - proves out the occlusion technique
-- that real enemies/pickups will reuse later. Unlike the wall columns, these
-- genuinely need per-frame repositioning (their screen X and size change
-- continuously as the player turns/moves), but there are only a few of them,
-- so that cost is negligible next to the 72 wall columns.
local SPRITE_SCALE = 0.45
local SPRITES = {
	{ x = (5 + 0.5) * CELL, y = (1 + 0.5) * CELL, color = { 1.0, 0.55, 0.15 } },
	{ x = (3 + 0.5) * CELL, y = (3 + 0.5) * CELL, color = { 0.95, 0.30, 0.20 } },
	{ x = (9 + 0.5) * CELL, y = (5 + 0.5) * CELL, color = { 1.0, 0.80, 0.20 } },
	{ x = (11 + 0.5) * CELL, y = (7 + 0.5) * CELL, color = { 0.90, 0.40, 0.15 } },
	{ x = (13 + 0.5) * CELL, y = (9 + 0.5) * CELL, color = { 1.0, 0.65, 0.10 } },
}
for _, sprite in ipairs(SPRITES) do
	sprite.tex = play:CreateTexture(nil, "OVERLAY")
	sprite.tex:SetColorTexture(sprite.color[1], sprite.color[2], sprite.color[3])
	sprite.miniDot = minimap:CreateTexture(nil, "OVERLAY")
	sprite.miniDot:SetSize(4, 4)
	sprite.miniDot:SetColorTexture(sprite.color[1], sprite.color[2], sprite.color[3])
	sprite.miniDot:SetPoint("TOPLEFT", minimap, "TOPLEFT",
		(sprite.x / CELL) * MINI_SCALE - 2, -(sprite.y / CELL) * MINI_SCALE - 2)
end

local function NormalizeAngle(a)
	a = a % (2 * math.pi)
	if a > math.pi then a = a - 2 * math.pi end
	return a
end

-- ===== Raycasting =====
-- Fixed-step marching rather than exact DDA: at this column count and render
-- distance the extra steps are trivial (well under a millisecond per frame),
-- and it's much easier to get right than exact grid-DDA edge cases.
local function CastRay(px, py, angle)
	local dirX, dirY = cos(angle), sin(angle)
	local dist = 0
	for _ = 1, MAX_STEPS do
		dist = dist + STEP_SIZE
		local rx, ry = px + dirX * dist, py + dirY * dist
		if IsWall(rx, ry) then
			local fracX = (rx % CELL) / CELL
			local fracY = (ry % CELL) / CELL
			local distToVerticalEdge = min(fracX, 1 - fracX)
			local distToHorizontalEdge = min(fracY, 1 - fracY)
			return dist, distToVerticalEdge < distToHorizontalEdge
		end
	end
	return MAX_RENDER_DIST, false
end

local function TryMove(nx, ny)
	if not IsWall(nx + PLAYER_RADIUS, ny) and not IsWall(nx - PLAYER_RADIUS, ny) then
		playerX = nx
	end
	if not IsWall(playerX, ny + PLAYER_RADIUS) and not IsWall(playerX, ny - PLAYER_RADIUS) then
		playerY = ny
	end
end

local zbuffer = {} -- corrected wall distance per column, for sprite occlusion

frame:SetScript("OnUpdate", function(self, elapsed)
	if held.left then playerAngle = playerAngle - TURN_SPEED * elapsed end
	if held.right then playerAngle = playerAngle + TURN_SPEED * elapsed end

	local moveDir = 0
	if held.forward then moveDir = moveDir + 1 end
	if held.back then moveDir = moveDir - 1 end
	if moveDir ~= 0 then
		local nx = playerX + cos(playerAngle) * moveDir * MOVE_SPEED * elapsed
		local ny = playerY + sin(playerAngle) * moveDir * MOVE_SPEED * elapsed
		TryMove(nx, ny)
	end

	local halfFov = FOV / 2
	for i = 1, NUM_COLUMNS do
		local col = columns[i]
		local rayAngle = playerAngle - halfFov + (i - 0.5) * (FOV / NUM_COLUMNS)
		local dist, sideHit = CastRay(playerX, playerY, rayAngle)
		local correctedDist = dist * cos(rayAngle - playerAngle)
		zbuffer[i] = correctedDist
		local wallH = min(PLAY_H, (CELL * PLAY_H) / (correctedDist + 1))

		if wallH ~= col.lastH then
			col.tex:SetHeight(wallH)
			col.lastH = wallH
		end

		local shade = max(0.2, 1 - correctedDist / MAX_RENDER_DIST)
		if sideHit then shade = shade * 0.7 end
		local shadeKey = floor(shade * 24)
		if shadeKey ~= col.lastShadeKey then
			col.tex:SetVertexColor(shade * 0.8, shade * 0.55, shade * 0.4)
			col.lastShadeKey = shadeKey
		end
	end

	for _, sprite in ipairs(SPRITES) do
		local dx, dy = sprite.x - playerX, sprite.y - playerY
		local dist = (dx * dx + dy * dy) ^ 0.5
		local angleToSprite = NormalizeAngle(math.atan2(dy, dx) - playerAngle)

		if dist < 1 or angleToSprite < -halfFov - 0.2 or angleToSprite > halfFov + 0.2 then
			sprite.tex:Hide()
		else
			local fraction = 0.5 + angleToSprite / FOV
			local colIndex = max(1, min(NUM_COLUMNS, floor(fraction * NUM_COLUMNS) + 1))

			if dist >= (zbuffer[colIndex] or MAX_RENDER_DIST) then
				sprite.tex:Hide()
			else
				local size = min(PLAY_H, (CELL * PLAY_H) / (dist + 1)) * SPRITE_SCALE
				sprite.tex:SetSize(size, size)
				sprite.tex:ClearAllPoints()
				sprite.tex:SetPoint("CENTER", play, "BOTTOMLEFT", fraction * PLAY_W, PLAY_H / 2)
				local shade = max(0.35, 1 - dist / MAX_RENDER_DIST)
				sprite.tex:SetVertexColor(shade, shade, shade)
				sprite.tex:Show()
			end
		end
	end

	miniPlayer:ClearAllPoints()
	miniPlayer:SetPoint("CENTER", minimap, "TOPLEFT",
		(playerX / CELL) * MINI_SCALE, -(playerY / CELL) * MINI_SCALE)
end)

-- ===== Input =====
local KEY_MAP = {
	W = "forward", UP = "forward",
	S = "back", DOWN = "back",
	A = "left", LEFT = "left",
	D = "right", RIGHT = "right",
}

frame:SetScript("OnKeyDown", function(self, key)
	local action = KEY_MAP[key]
	if action then
		held[action] = true
		self:SetPropagateKeyboardInput(false)
	elseif key == "ESCAPE" then
		self:Hide()
		self:SetPropagateKeyboardInput(false)
	else
		self:SetPropagateKeyboardInput(true)
	end
end)

frame:SetScript("OnKeyUp", function(self, key)
	local action = KEY_MAP[key]
	if action then
		held[action] = false
		self:SetPropagateKeyboardInput(false)
	else
		self:SetPropagateKeyboardInput(true)
	end
end)

frame:SetScript("OnShow", function(self)
	self:EnableKeyboard(true)
end)

frame:SetScript("OnHide", function(self)
	self:EnableKeyboard(false)
	held.forward, held.back, held.left, held.right = false, false, false, false
end)

-- ===== Slash commands =====
SLASH_WOWDOOM1 = "/wowdoom"
SlashCmdList.WOWDOOM = function()
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end
