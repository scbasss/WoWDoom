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
local MAX_STEPS        = 24          -- max grid-cell boundaries a ray may cross (DDA advances ~1 cell/step)
local MAX_RENDER_DIST  = MAX_STEPS * CELL
local MOVE_SPEED       = 130         -- world units / sec
local TURN_SPEED       = 2.6         -- radians / sec
local PLAYER_RADIUS    = 12

local PLAYER_MAX_HP    = 100
local ENEMY_MAX_HP     = 100
local ENEMY_SPEED      = 70
local ENEMY_RADIUS     = 14
local ENEMY_DETECT_RADIUS = 260
local ENEMY_STOP_DIST  = 45
local ENEMY_CONTACT_DPS = 18
local SHOOT_RANGE      = MAX_RENDER_DIST
local SHOOT_CONE       = 0.12        -- radians either side of center
local SHOOT_DAMAGE     = 34
local SHOOT_COOLDOWN   = 0.35        -- seconds between shots

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
local PLAYER_START_X, PLAYER_START_Y = (2 + 0.5) * CELL, (1 + 0.5) * CELL
local playerX, playerY = PLAYER_START_X, PLAYER_START_Y
local playerAngle = 0
local playerHP = PLAYER_MAX_HP
local gameState = "playing" -- playing | dead
local shootCooldown = 0

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
helpText:SetText("WASD / Arrows to move + turn. Space / click to shoot.")

-- Health bar
local hpBarBG = frame:CreateTexture(nil, "ARTWORK")
hpBarBG:SetSize(200, 14)
hpBarBG:SetPoint("TOP", helpText, "BOTTOM", 0, -8)
hpBarBG:SetColorTexture(0.12, 0.12, 0.12)

local hpBarFill = frame:CreateTexture(nil, "ARTWORK", nil, 1)
hpBarFill:SetPoint("TOPLEFT", hpBarBG, "TOPLEFT", 2, -2)
hpBarFill:SetPoint("BOTTOMLEFT", hpBarBG, "BOTTOMLEFT", 2, 2)
hpBarFill:SetWidth(196)
hpBarFill:SetColorTexture(0.75, 0.15, 0.15)

local hpText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hpText:SetPoint("CENTER", hpBarBG, "CENTER")

local function UpdateHPBar()
	local pct = max(0, playerHP / PLAYER_MAX_HP)
	hpBarFill:SetWidth(max(1, 196 * pct))
	hpText:SetText(("HP: %d"):format(max(0, floor(playerHP))))
end
UpdateHPBar()

-- Play area
local play = CreateFrame("Frame", nil, frame)
play:SetSize(PLAY_W, PLAY_H)
play:SetPoint("BOTTOM", 0, 20)
if play.SetClipsChildren then play:SetClipsChildren(true) end
play:EnableMouse(true)

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

-- Death / restart overlay
local deathMsg = play:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
deathMsg:SetPoint("CENTER")
deathMsg:SetText("You Died")
deathMsg:Hide()

local deathSubMsg = play:CreateFontString(nil, "OVERLAY", "GameFontNormal")
deathSubMsg:SetPoint("TOP", deathMsg, "BOTTOM", 0, -10)
deathSubMsg:SetText("Click or press Space to respawn")
deathSubMsg:Hide()

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
local function CreateBillboardVisuals(obj, dotSize)
	obj.tex = play:CreateTexture(nil, "OVERLAY")
	obj.tex:SetColorTexture(obj.color[1], obj.color[2], obj.color[3])
	obj.miniDot = minimap:CreateTexture(nil, "OVERLAY")
	obj.miniDot:SetSize(dotSize, dotSize)
	obj.miniDot:SetColorTexture(obj.color[1], obj.color[2], obj.color[3])
end

local function PositionMiniDot(obj, dotSize)
	obj.miniDot:ClearAllPoints()
	obj.miniDot:SetPoint("TOPLEFT", minimap, "TOPLEFT",
		(obj.x / CELL) * MINI_SCALE - dotSize / 2, -(obj.y / CELL) * MINI_SCALE - dotSize / 2)
end

for _, sprite in ipairs(SPRITES) do
	CreateBillboardVisuals(sprite, 4)
	PositionMiniDot(sprite, 4)
end

-- ===== Enemies: chase the player, deal contact damage, die to gunfire. =====
local ENEMIES = {
	{ x = (5 + 0.5) * CELL, y = (6 + 0.5) * CELL, color = { 0.75, 0.1, 0.65 } },
	{ x = (7 + 0.5) * CELL, y = (8 + 0.5) * CELL, color = { 0.75, 0.1, 0.65 } },
	{ x = (5 + 0.5) * CELL, y = (9 + 0.5) * CELL, color = { 0.75, 0.1, 0.65 } },
}
for _, enemy in ipairs(ENEMIES) do
	enemy.scale = 0.6
	enemy.hp = ENEMY_MAX_HP
	enemy.dead = false
	enemy.hitFlash = 0
	enemy.spawnX, enemy.spawnY = enemy.x, enemy.y
	CreateBillboardVisuals(enemy, 5)
	PositionMiniDot(enemy, 5)
end

-- All billboarded objects together, so they can be depth-sorted as one set -
-- otherwise an enemy would always paint over a torch (or vice versa) regardless
-- of which is actually closer, since WoW draws same-layer textures in creation
-- order by default, not by distance.
local ALL_BILLBOARDS = {}
for _, sprite in ipairs(SPRITES) do tinsert(ALL_BILLBOARDS, sprite) end
for _, enemy in ipairs(ENEMIES) do tinsert(ALL_BILLBOARDS, enemy) end

local function NormalizeAngle(a)
	a = a % (2 * math.pi)
	if a > math.pi then a = a - 2 * math.pi end
	return a
end

-- ===== Raycasting =====
-- Exact DDA (Lode Vandevenne's classic algorithm - the reference nearly every
-- JS/C raycaster, including Wolfenstein 3D itself, is built on): step precisely
-- to the next grid-cell boundary each iteration instead of marching in small
-- fixed increments. Cheaper (fewer iterations) and exact (can't step over a
-- thin wall), and it yields the fisheye-corrected perpendicular distance
-- directly - no separate cos() correction needed afterward.
local INF = 1e30

local function CastRay(px, py, angle)
	local dirX, dirY = cos(angle), sin(angle)
	local cellX, cellY = px / CELL, py / CELL
	local mapX, mapY = floor(cellX), floor(cellY)

	local deltaDistX = (dirX == 0) and INF or math.abs(1 / dirX)
	local deltaDistY = (dirY == 0) and INF or math.abs(1 / dirY)

	local stepX, sideDistX
	if dirX < 0 then
		stepX, sideDistX = -1, (cellX - mapX) * deltaDistX
	else
		stepX, sideDistX = 1, (mapX + 1 - cellX) * deltaDistX
	end

	local stepY, sideDistY
	if dirY < 0 then
		stepY, sideDistY = -1, (cellY - mapY) * deltaDistY
	else
		stepY, sideDistY = 1, (mapY + 1 - cellY) * deltaDistY
	end

	local hitVertical = false
	for _ = 1, MAX_STEPS do
		if sideDistX < sideDistY then
			sideDistX = sideDistX + deltaDistX
			mapX = mapX + stepX
			hitVertical = true
		else
			sideDistY = sideDistY + deltaDistY
			mapY = mapY + stepY
			hitVertical = false
		end

		if mapX < 0 or mapY < 0 or mapX >= MAP_W or mapY >= MAP_H or MAP[mapY + 1][mapX + 1] == 1 then
			local perpDist
			if hitVertical then
				perpDist = (mapX - cellX + (1 - stepX) / 2) / dirX
			else
				perpDist = (mapY - cellY + (1 - stepY) / 2) / dirY
			end
			return perpDist * CELL, hitVertical
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

local zbuffer = {} -- corrected wall distance per column, for sprite/enemy occlusion

-- Renders one billboarded object (torch or enemy) against the current z-buffer.
-- Shared by SPRITES and ENEMIES so occlusion/sizing math only lives in one place.
local function UpdateBillboard(obj, halfFov)
	if obj.dead then
		obj.tex:Hide()
		return
	end
	local dx, dy = obj.x - playerX, obj.y - playerY
	local dist = (dx * dx + dy * dy) ^ 0.5
	local angleTo = NormalizeAngle(math.atan2(dy, dx) - playerAngle)

	if dist < 1 or angleTo < -halfFov - 0.2 or angleTo > halfFov + 0.2 then
		obj.tex:Hide()
		return
	end

	local fraction = 0.5 + angleTo / FOV
	local colIndex = max(1, min(NUM_COLUMNS, floor(fraction * NUM_COLUMNS) + 1))
	if dist >= (zbuffer[colIndex] or MAX_RENDER_DIST) then
		obj.tex:Hide()
		return
	end

	local size = min(PLAY_H, (CELL * PLAY_H) / (dist + 1)) * (obj.scale or SPRITE_SCALE)
	obj.tex:SetSize(size, size)
	obj.tex:ClearAllPoints()
	obj.tex:SetPoint("CENTER", play, "BOTTOMLEFT", fraction * PLAY_W, PLAY_H / 2)

	if obj.hitFlash and obj.hitFlash > 0 then
		obj.tex:SetVertexColor(1, 1, 1)
	else
		local shade = max(0.35, 1 - dist / MAX_RENDER_DIST)
		obj.tex:SetVertexColor(shade, shade, shade)
	end
	obj.tex:Show()
end

local function TryMoveEnemy(enemy, nx, ny)
	if not IsWall(nx + ENEMY_RADIUS, ny) and not IsWall(nx - ENEMY_RADIUS, ny) then
		enemy.x = nx
	end
	if not IsWall(enemy.x, ny + ENEMY_RADIUS) and not IsWall(enemy.x, ny - ENEMY_RADIUS) then
		enemy.y = ny
	end
end

local function UpdateEnemyAI(enemy, elapsed)
	if enemy.dead then return end
	if enemy.hitFlash and enemy.hitFlash > 0 then
		enemy.hitFlash = enemy.hitFlash - elapsed
	end

	local dx, dy = playerX - enemy.x, playerY - enemy.y
	local dist = (dx * dx + dy * dy) ^ 0.5

	if dist < ENEMY_DETECT_RADIUS then
		if dist > ENEMY_STOP_DIST then
			local nx = enemy.x + (dx / dist) * ENEMY_SPEED * elapsed
			local ny = enemy.y + (dy / dist) * ENEMY_SPEED * elapsed
			TryMoveEnemy(enemy, nx, ny)
		else
			playerHP = playerHP - ENEMY_CONTACT_DPS * elapsed
		end
	end

	PositionMiniDot(enemy, 5)
end

frame:SetScript("OnUpdate", function(self, elapsed)
	if gameState ~= "playing" then return end

	if shootCooldown > 0 then shootCooldown = shootCooldown - elapsed end

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
		local correctedDist, sideHit = CastRay(playerX, playerY, rayAngle)
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

	for _, enemy in ipairs(ENEMIES) do
		UpdateEnemyAI(enemy, elapsed)
	end

	if playerHP <= 0 then
		playerHP = 0
		gameState = "dead"
		deathMsg:Show()
		deathSubMsg:Show()
	end
	UpdateHPBar()

	-- Depth-sort every billboard together (farthest first) and paint in that
	-- order via draw-layer sublevels, so a nearer torch correctly covers a
	-- farther enemy (or vice versa) instead of it being decided by creation order.
	for _, obj in ipairs(ALL_BILLBOARDS) do
		if obj.dead then
			obj._dist = -1
		else
			local dx, dy = obj.x - playerX, obj.y - playerY
			obj._dist = (dx * dx + dy * dy) ^ 0.5
		end
	end
	table.sort(ALL_BILLBOARDS, function(a, b) return a._dist > b._dist end)
	for idx, obj in ipairs(ALL_BILLBOARDS) do
		obj.tex:SetDrawLayer("OVERLAY", max(-8, min(7, -8 + (idx - 1))))
		UpdateBillboard(obj, halfFov)
	end

	miniPlayer:ClearAllPoints()
	miniPlayer:SetPoint("CENTER", minimap, "TOPLEFT",
		(playerX / CELL) * MINI_SCALE, -(playerY / CELL) * MINI_SCALE)
end)

-- ===== Shooting & respawn =====
local function Shoot()
	if gameState ~= "playing" or shootCooldown > 0 then return end
	shootCooldown = SHOOT_COOLDOWN

	local halfFov = FOV / 2
	local bestEnemy, bestDist = nil, math.huge
	for _, enemy in ipairs(ENEMIES) do
		if not enemy.dead then
			local dx, dy = enemy.x - playerX, enemy.y - playerY
			local dist = (dx * dx + dy * dy) ^ 0.5
			local angleTo = NormalizeAngle(math.atan2(dy, dx) - playerAngle)
			if dist <= SHOOT_RANGE and math.abs(angleTo) <= SHOOT_CONE then
				local fraction = 0.5 + angleTo / FOV
				local colIndex = max(1, min(NUM_COLUMNS, floor(fraction * NUM_COLUMNS) + 1))
				if dist < (zbuffer[colIndex] or MAX_RENDER_DIST) and dist < bestDist then
					bestEnemy, bestDist = enemy, dist
				end
			end
		end
	end

	if bestEnemy then
		bestEnemy.hp = bestEnemy.hp - SHOOT_DAMAGE
		bestEnemy.hitFlash = 0.15
		if bestEnemy.hp <= 0 then
			bestEnemy.dead = true
			bestEnemy.tex:Hide()
			bestEnemy.miniDot:Hide()
		end
	end
end

local function Respawn()
	playerX, playerY = PLAYER_START_X, PLAYER_START_Y
	playerAngle = 0
	playerHP = PLAYER_MAX_HP
	for _, enemy in ipairs(ENEMIES) do
		enemy.hp = ENEMY_MAX_HP
		enemy.dead = false
		enemy.hitFlash = 0
		enemy.x, enemy.y = enemy.spawnX, enemy.spawnY
		enemy.miniDot:Show()
	end
	UpdateHPBar()
	deathMsg:Hide()
	deathSubMsg:Hide()
	gameState = "playing"
end

play:SetScript("OnMouseDown", function()
	if gameState == "dead" then Respawn() else Shoot() end
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
	elseif key == "SPACE" then
		if gameState == "dead" then Respawn() else Shoot() end
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
