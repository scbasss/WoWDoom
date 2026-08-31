-- WoW Doom: a raycasting engine reimplemented against World of Warcraft's UI frame API.
-- This is NOT id Software's DOOM code or game data (that couldn't run in the addon
-- sandbox at all - no FFI, no native code, no external processes). The engine is an
-- original Wolfenstein/DOOM-style raycaster: hand-built mazes, cast in Lua, drawn as
-- shaded vertical strips using WoW Textures - the same primitive used for everything
-- else in this AddOns folder. Two sprites (enemy creature, torch) are real extracted
-- Freedoom art (BSD-licensed original replacement game-data, not id's) - see
-- textures/README.md for exactly what was taken from where.
--
-- Performance approach (learned from how other "DOOM on constrained surfaces" ports
-- actually stay usable, e.g. the DOOM-on-Google-Sheets project explicitly rendering
-- low-res and only touching cells that changed):
--   1. Low column count (one Texture per screen column) instead of real pixel
--      resolution - this is the actual cost driver, not the ray math.
--   2. Each column's Texture is anchored ONCE, by its center, and never re-anchored.
--      Every frame we only ever call SetHeight/SetVertexColor, and only when the
--      value actually changed since last frame.
--   3. Depth-sorted billboards (sublevel per distance rank) instead of per-pixel
--      compositing, and exact DDA raycasting (Lode Vandevenne's classic algorithm)
--      instead of fixed-step marching.

-- ===== Config =====
local FRAME_W, FRAME_H = 560, 470
local PLAY_W, PLAY_H   = 520, 340
local NUM_COLUMNS      = 72
-- Matches MAX_PORTAL_DEPTH below (each portal hop can add at most one layer, so
-- that's the real worst case) - keep these two in lockstep or CastRayLines can
-- silently return more layers than there are texture slots to draw them in.
local LAYERS_PER_COLUMN = 4
local FOV              = math.rad(66)
local CELL             = 64          -- world units per map cell
local RENDER_DIST_CELLS = 24          -- draw distance, in cells, before a ray just fades to nothing
local MAX_RENDER_DIST  = RENDER_DIST_CELLS * CELL
local MOVE_SPEED       = 130         -- world units / sec
local TURN_SPEED       = 2.6         -- radians / sec
local PLAYER_RADIUS    = 12
local EXIT_RADIUS      = CELL * 0.6

-- Vertical scale: a "full height" wall spans CELL world-units (0 -> CELL), matching
-- a grid cell's horizontal size for roughly cube-shaped normal rooms - this exactly
-- reproduces the old fixed-full-height wall math when a sector's floor=0/ceiling=CELL,
-- so existing uniform-height levels render identically once compiled through the
-- new multi-sector system.
local SECTOR_CEILING   = CELL        -- all sectors currently share one ceiling height
local RAISED_FLOOR     = CELL * 0.5  -- demo raised-platform floor height
local EYE_HEIGHT       = CELL * 0.5  -- camera height above whichever sector floor the player is standing on
local MAX_PORTAL_DEPTH = 4           -- max sector crossings rendered per ray (riser/header layers)

local PLAYER_MAX_HP    = 100
local ENEMY_RADIUS     = 14
local ENEMY_DETECT_RADIUS = 260
local ENEMY_STOP_DIST  = 45
local SHOOT_RANGE      = MAX_RENDER_DIST
local SHOOT_CONE       = 0.12        -- radians either side of center
local SHOOT_DAMAGE     = 34
local SHOOT_COOLDOWN   = 0.35        -- seconds between shots

local cos, sin, floor, min, max = math.cos, math.sin, math.floor, math.min, math.max

local function ClearArray(t)
	for i = #t, 1, -1 do t[i] = nil end
end

-- ===== Levels =====
-- Each level is its own hand-built maze (original layouts, not extracted DOOM/Freedoom
-- map data - see the README for why: our engine is a uniform-grid raycaster on purpose,
-- and real DOOM levels aren't grid-shaped, so importing them would mean either mangling
-- them unrecognizably or rewriting this into a full sector/BSP engine). Structurally
-- this mirrors how DOOM source ports like ZDoom define progression (a MAPINFO lump
-- saying which map follows which) - just simple enough to be a plain Lua table.
-- '1' = wall, '0' = open floor, '2' = exit (walkable; reaching it advances the
-- level), '3' = raised platform (open floor at RAISED_FLOOR height instead of 0 -
-- proof of concept for real variable-height sectors, approached from the west/north).
local LEVELS = {
	{
		mapRows = {
			"1111111111111111",
			"1000000000000001",
			"1011110111011101",
			"1010333100010001",
			"1010111101110101",
			"1000100000000101",
			"1110101111110101",
			"1000101000000101",
			"1011101011111101",
			"1000001010000201",
			"1011111010111101",
			"1111111111111111",
		},
		name = "The Outpost",
		wallTexture = "Interface\\AddOns\\WoWDoom\\textures\\wall_outpost.tga", -- Freedoom STONEW1
		ceilingColor = { 0.22, 0.22, 0.26 },
		floorColor = { 0.35, 0.32, 0.28 },
		playerStart = { 2, 1, 0 },
		enemySpawns = {
			{ 5, 6, "zombie" }, { 7, 8, "zombie" }, { 5, 9, "zombie" },
		},
		torchSpawns = {
			{ 5, 1, "N" }, { 3, 3, "N" }, { 9, 5, "N" }, { 11, 7, "N" }, { 13, 9, "N" },
		},
	},
	{
		mapRows = {
			"111111111111111111",
			"100000001100000001",
			"101110101101110101",
			"101000101000010101",
			"101011101011110101",
			"100010000010000001",
			"111010111110111101",
			"100010100000101001",
			"101110101110101101",
			"100000100010001001",
			"101111101010101101",
			"100000001010001001",
			"101110111010111101",
			"100000000000000201",
			"111111111111111111",
		},
		name = "The Garrison",
		wallTexture = "Interface\\AddOns\\WoWDoom\\textures\\wall_garrison.tga", -- Freedoom COMP01_1
		ceilingColor = { 0.20, 0.17, 0.15 },
		floorColor = { 0.30, 0.24, 0.18 },
		playerStart = { 2, 1, 0 },
		enemySpawns = {
			{ 9, 3, "zombie" }, { 3, 7, "shotgunguy" }, { 13, 9, "shotgunguy" }, { 7, 11, "zombie" },
		},
		torchSpawns = {
			{ 5, 1, "N" }, { 15, 1, "N" }, { 9, 5, "S" }, { 3, 11, "N" }, { 15, 9, "N" },
		},
	},
	{
		mapRows = {
			"11111111111111111111",
			"10000000000000000001",
			"10111110111110111101",
			"10100010001000010101",
			"10101110101011110101",
			"10101000101010000101",
			"10101011101010111101",
			"10001010001000100001",
			"11101010111011101011",
			"10001000100010001001",
			"10111011101110111101",
			"10100010001000010101",
			"10101110111110101101",
			"10000010000010000001",
			"10111010111010111101",
			"10000000000000000201",
			"11111111111111111111",
		},
		name = "The Pit",
		wallTexture = "Interface\\AddOns\\WoWDoom\\textures\\wall_pit.tga", -- Freedoom HELL5_1
		ceilingColor = { 0.16, 0.05, 0.05 },
		floorColor = { 0.30, 0.08, 0.06 },
		playerStart = { 2, 1, 0 },
		enemySpawns = {
			{ 9, 3, "shotgunguy" }, { 15, 5, "demon" }, { 5, 9, "demon" },
			{ 13, 11, "demon" }, { 9, 13, "shotgunguy" },
		},
		torchSpawns = {
			{ 5, 1, "N" }, { 17, 1, "N" }, { 3, 5, "E" }, { 15, 9, "S" }, { 9, 11, "S" },
		},
	},
}

local MAP, MAP_W, MAP_H -- current level; rebuilt by LoadLevel()

local function IsWall(worldX, worldY)
	local cx = floor(worldX / CELL) + 1
	local cy = floor(worldY / CELL) + 1
	if cx < 1 or cy < 1 or cx > MAP_W or cy > MAP_H then return true end
	return MAP[cy][cx] == 1
end

-- ===== Grid -> sector/line compiler (engine v3) =====
-- Bridges our hand-built grid mazes onto a real sector-based raycaster: instead
-- of one flat height per level, connected same-floor-height cells are flood-
-- filled into distinct sectors, and boundaries become lines - solid (one side is
-- a wall) or portals (both sides are sectors, of possibly different heights).
-- This is a from-scratch reconstruction of DOOM's actual open/closed portal
-- semantics (confirmed against PrBoom's r_bsp.c: a portal is "closed"/solid if
-- the neighboring floor is higher - deliberately NOT porting PrBoom's BSP-tree +
-- solidcol[] traversal itself, since that's a 1993-hardware performance
-- optimization for avoiding overdraw, not something that changes what's drawn -
-- our brute-force nearest-hit-per-column already gets the identical correct
-- result at our scale (dozens of segments), so reconstructing a BSP tree on top
-- would just be replicating a constraint we don't have).
--
-- Collision still uses the grid/IsWall directly (a height difference doesn't
-- block movement in this pass - matches classic DOOM's step-up behavior closely
-- enough without needing a max-step-height model yet).
local function CompileGridToSectors(mapRows)
	local h, w = #mapRows, #mapRows[1]
	local FLOOR_HEIGHT_OF = { ["0"] = 0, ["2"] = 0, ["3"] = RAISED_FLOOR }

	local function ch(x, y) -- 0-indexed; out of bounds reads as wall
		if x < 0 or y < 0 or x >= w or y >= h then return "1" end
		return mapRows[y + 1]:sub(x + 1, x + 1)
	end

	-- Flood-fill connected same-floor-height cells into sectors.
	local cellSector, visited = {}, {}
	for y = 0, h - 1 do cellSector[y], visited[y] = {}, {} end
	local sectors = {}

	local NEIGHBOR_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local c = ch(x, y)
			if c == "1" then
				cellSector[y][x] = false
			elseif not visited[y][x] then
				local targetHeight = FLOOR_HEIGHT_OF[c] or 0
				local sIdx = #sectors + 1
				sectors[sIdx] = { floor = targetHeight, ceiling = SECTOR_CEILING }
				local queue, qi = { { x, y } }, 1
				visited[y][x] = true
				while qi <= #queue do
					local cx, cy = queue[qi][1], queue[qi][2]
					qi = qi + 1
					cellSector[cy][cx] = sIdx
					for _, d in ipairs(NEIGHBOR_OFFSETS) do
						local nx, ny = cx + d[1], cy + d[2]
						if nx >= 0 and ny >= 0 and nx < w and ny < h and not visited[ny][nx] then
							local nc = ch(nx, ny)
							if nc ~= "1" and (FLOOR_HEIGHT_OF[nc] or 0) == targetHeight then
								visited[ny][nx] = true
								tinsert(queue, { nx, ny })
							end
						end
					end
				end
			end
		end
	end

	local function sideAt(x, y)
		if x < 0 or y < 0 or x >= w or y >= h then return false end
		return cellSector[y][x]
	end
	local function samePair(a1, b1, a2, b2)
		return (a1 == a2 and b1 == b2) or (a1 == b2 and b1 == a2)
	end

	-- Boundary edges become lines, merging consecutive edges that divide the
	-- SAME pair of sectors (a straight wall becomes 1 segment, not N - see perf
	-- note further down; this also now correctly splits wherever the
	-- neighboring sector actually changes, e.g. at a platform's edge).
	local lines = {}
	for y = 0, h do -- horizontal edges (north/south-facing)
		local runStart, runA, runB = nil, nil, nil
		for x = 0, w do
			local a = x < w and sideAt(x, y - 1) or false
			local b = x < w and sideAt(x, y) or false
			local hasEdge = x < w and a ~= b
			if hasEdge and not runStart then
				runStart, runA, runB = x, a, b
			elseif runStart and (not hasEdge or not samePair(a, b, runA, runB)) then
				tinsert(lines, { runStart * CELL, y * CELL, x * CELL, y * CELL, false, runA, runB })
				if hasEdge then runStart, runA, runB = x, a, b else runStart = nil end
			end
		end
	end
	for x = 0, w do -- vertical edges (east/west-facing)
		local runStart, runA, runB = nil, nil, nil
		for y = 0, h do
			local a = y < h and sideAt(x - 1, y) or false
			local b = y < h and sideAt(x, y) or false
			local hasEdge = y < h and a ~= b
			if hasEdge and not runStart then
				runStart, runA, runB = y, a, b
			elseif runStart and (not hasEdge or not samePair(a, b, runA, runB)) then
				tinsert(lines, { x * CELL, runStart * CELL, x * CELL, y * CELL, true, runA, runB })
				if hasEdge then runStart, runA, runB = y, a, b else runStart = nil end
			end
		end
	end

	return lines, sectors, cellSector
end

-- Ray (origin O, unit direction D) vs. segment (A -> B). Returns distance
-- along D (a true Euclidean distance since D is unit-length) and the
-- fractional position [0,1) along the segment (for texture sampling), or
-- nil if they don't intersect in front of the ray.
-- Standard 2D ray/segment intersection via the direction-perpendicular trick;
-- same family of math as Lode's raycasting tutorial, generalized from
-- grid-aligned lines to arbitrary ones.
local function RayIntersectSegment(ox, oy, dx, dy, ax, ay, bx, by)
	local v1x, v1y = ox - ax, oy - ay
	local v2x, v2y = bx - ax, by - ay
	local v3x, v3y = -dy, dx

	local dot = v2x * v3x + v2y * v3y
	if dot > -1e-9 and dot < 1e-9 then return nil end -- parallel

	local t1 = (v2x * v1y - v2y * v1x) / dot
	local t2 = (v1x * v3x + v1y * v3y) / dot

	if t1 >= 0 and t2 >= 0 and t2 <= 1 then
		return t1, t2
	end
	return nil
end

-- Casts through open portals (equal-or-descending floor height) to see into
-- adjacent rooms, exactly DOOM's "open" case. An ascending-floor portal (a
-- platform ahead) records a riser layer (the step's face) but - unlike the
-- first version of this - does NOT stop the ray there: it keeps walking into
-- the far sector, so a column can end up with several layers (e.g. a riser
-- plus the far wall beyond/above it), composited near-to-far by the caller.
-- Returns the layer list and the distance to the ultimate solid stop (used for
-- sprite/enemy occlusion - see the zbuffer comment at the call site for why
-- that's the more useful value there than the nearest layer's distance).
local function CastRayLines(px, py, angle, lines, sectors, startSectorIdx)
	local dirX, dirY = cos(angle), sin(angle)
	local ox, oy = px, py
	local traveled = 0
	local curSectorIdx = startSectorIdx
	local layers = {}

	for _ = 1, MAX_PORTAL_DEPTH do
		local bestT, bestLine = MAX_RENDER_DIST, nil
		for _, line in ipairs(lines) do
			local t = RayIntersectSegment(ox, oy, dirX, dirY, line[1], line[2], line[3], line[4])
			if t and t < bestT then
				bestT, bestLine = t, line
			end
		end

		if not bestLine then
			return layers, traveled + MAX_RENDER_DIST
		end

		-- NOT the "a and b or c" idiom here: bestLine[7] can legitimately be
		-- `false` (a solid wall), and that idiom silently breaks whenever the
		-- "true" branch value is itself falsy.
		local otherIdx
		if bestLine[6] == curSectorIdx then
			otherIdx = bestLine[7]
		else
			otherIdx = bestLine[6]
		end
		local _, wallX = RayIntersectSegment(ox, oy, dirX, dirY, bestLine[1], bestLine[2], bestLine[3], bestLine[4])
		local totalDist = traveled + bestT

		if not otherIdx then -- solid: one side is a wall - final layer, ray stops here
			local sector = sectors[curSectorIdx]
			tinsert(layers, {
				dist = totalDist, isVertical = bestLine[5], wallX = wallX,
				zBottom = sector.floor, zTop = sector.ceiling,
			})
			return layers, totalDist
		end

		local nearSector, farSector = sectors[curSectorIdx], sectors[otherIdx]
		if farSector.floor > nearSector.floor then -- ascending step: record the riser face, keep going
			tinsert(layers, {
				dist = totalDist, isVertical = bestLine[5], wallX = wallX,
				zBottom = nearSector.floor, zTop = farSector.floor,
			})
		end
		-- level or descending: fully open, no layer to draw for this crossing at all

		ox, oy = ox + dirX * (bestT + 0.01), oy + dirY * (bestT + 0.01)
		traveled = totalDist
		curSectorIdx = otherIdx
	end

	return layers, traveled + MAX_RENDER_DIST
end

-- Projects a world-space vertical span [zBottom, zTop] (e.g. a sector's floor to
-- ceiling, or a riser's floor-to-floor face) to a screen-space center offset and
-- height, relative to the camera's eye height. Reduces to the old fixed
-- full-wall math exactly when zBottom=0, zTop=CELL, eyeZ=CELL/2 (the previous
-- assumption for every wall), so uniform-height levels are unaffected.
local function ComputeSlice(dist, zBottom, zTop, eyeZ)
	local proj = PLAY_H / (dist + 1)
	local mid = (zBottom + zTop) / 2 - eyeZ
	local centerY = PLAY_H / 2 + mid * proj
	local height = min(PLAY_H * 4, (zTop - zBottom) * proj)
	return centerY, height
end

-- ===== Player / run state =====
local playerX, playerY, playerAngle = 0, 0, 0
local playerHP = PLAYER_MAX_HP
local playerSectorIdx = 1 -- which compiled sector the player currently stands in; drives eye height
local gameState = "playing" -- playing | dead | levelcomplete | won
local shootCooldown = 0
local currentLevelIndex = 1
local levelExitX, levelExitY = 0, 0

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

local levelText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
levelText:SetPoint("TOPRIGHT", -30, -18)

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

-- Ceiling / floor: anchored once; color is re-set per level (LoadLevel) for the
-- thematic escalation (cool stone -> grimy -> hellish red), never touched per-frame.
local ceiling = play:CreateTexture(nil, "BACKGROUND")
ceiling:SetPoint("TOPLEFT")
ceiling:SetPoint("TOPRIGHT")
ceiling:SetHeight(PLAY_H / 2)

local floorTex = play:CreateTexture(nil, "BACKGROUND")
floorTex:SetPoint("BOTTOMLEFT")
floorTex:SetPoint("BOTTOMRIGHT")
floorTex:SetHeight(PLAY_H / 2)

-- Overlay messages: death/retry and level-complete/win, same layout, different text.
local bigMsg = play:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
bigMsg:SetPoint("CENTER")
bigMsg:Hide()

local subMsg = play:CreateFontString(nil, "OVERLAY", "GameFontNormal")
subMsg:SetPoint("TOP", bigMsg, "BOTTOM", 0, -10)
subMsg:Hide()

local function ShowOverlay(big, sub)
	bigMsg:SetText(big)
	subMsg:SetText(sub)
	bigMsg:Show()
	subMsg:Show()
end

local function HideOverlay()
	bigMsg:Hide()
	subMsg:Hide()
end

-- ===== Column pool: each column is up to LAYERS_PER_COLUMN stacked texture
-- slices (e.g. a riser plus the far wall beyond/above it), so steps/platforms
-- actually composite instead of just replacing what's behind them. Every
-- layer's texture is created once; column count and layer count don't depend
-- on the map, so the pool itself never needs rebuilding between levels - only
-- which wall texture it samples from, set once per level load.
--
-- Each layer's SetPoint is touched only when its vertical CENTER actually
-- moves (dirty-checked, like height/color/texcoord) - not anchored forever,
-- since a riser or a change in the player's own eye height (standing on a
-- platform) shifts where a slice sits, not just how tall it is. Still cheap
-- at NUM_COLUMNS * LAYERS_PER_COLUMN = 216 texture objects.
local columns = {}
do
	local colW = PLAY_W / NUM_COLUMNS
	for i = 1, NUM_COLUMNS do
		local col = { x = (i - 0.5) * colW, layers = {} }
		for l = 1, LAYERS_PER_COLUMN do
			local layer = {}
			layer.tex = play:CreateTexture(nil, "ARTWORK", nil, LAYERS_PER_COLUMN - l) -- nearer layers drawn on top
			layer.tex:SetWidth(colW + 1) -- +1 avoids hairline seams between columns
			layer.tex:SetPoint("CENTER", play, "BOTTOMLEFT", col.x, PLAY_H / 2)
			layer.tex:SetHeight(PLAY_H)
			layer.tex:Hide()
			layer.lastH = PLAY_H
			layer.lastCenterYKey = floor((PLAY_H / 2) * 4)
			layer.lastShadeKey = nil
			layer.lastWallXKey = nil
			layer.shown = false
			col.layers[l] = layer
		end
		columns[i] = col
	end
end

-- ===== Minimap: frame created once; size + wall cells rebuilt per level. =====
local MINI_SCALE = 4
local minimap = CreateFrame("Frame", nil, frame)
minimap:SetPoint("TOPLEFT", play, "TOPLEFT", 6, -6)
local minimapBG = minimap:CreateTexture(nil, "BACKGROUND")
minimapBG:SetAllPoints()
minimapBG:SetColorTexture(0, 0, 0, 0.5)
local minimapWallCells = {}

local function RebuildMinimap()
	minimap:SetSize(MAP_W * MINI_SCALE, MAP_H * MINI_SCALE)
	for _, cell in ipairs(minimapWallCells) do cell:Hide() end
	ClearArray(minimapWallCells)
	for y = 1, MAP_H do
		for x = 1, MAP_W do
			if MAP[y][x] == 1 then
				local cell = minimap:CreateTexture(nil, "ARTWORK")
				cell:SetSize(MINI_SCALE, MINI_SCALE)
				cell:SetPoint("TOPLEFT", minimap, "TOPLEFT", (x - 1) * MINI_SCALE, -(y - 1) * MINI_SCALE)
				cell:SetColorTexture(0.7, 0.7, 0.75)
				tinsert(minimapWallCells, cell)
			end
		end
	end
end

local miniPlayer = minimap:CreateTexture(nil, "OVERLAY")
miniPlayer:SetSize(5, 5)
miniPlayer:SetColorTexture(1, 0.2, 0.2)

-- ===== Billboards: torches (SPRITES) and monsters (ENEMIES), depth-sorted together
-- (ALL_BILLBOARDS) against the wall z-buffer each frame. Rebuilt per level. =====
-- Torch sprite is Freedoom TREDA0 (see textures/README.md), 21x90 source pixels -
-- tall and thin, hence its own aspect ratio.
local TORCH_TEXTURE = "Interface\\AddOns\\WoWDoom\\textures\\torch.tga"
local TORCH_ASPECT = 21 / 90
local TORCH_DOT_COLOR = { 1.0, 0.65, 0.15 }
local TORCH_SCALE = 0.55
-- Nudges a torch from its cell's center toward one wall face, so it reads as
-- mounted rather than floating in the open. "N"/"S"/"E"/"W" must actually be a
-- wall in that level's grid - verified by hand against each level's layout.
local TORCH_WALL_OFFSET = CELL * 0.38
local SIDE_OFFSET = {
	N = { 0, -TORCH_WALL_OFFSET }, S = { 0, TORCH_WALL_OFFSET },
	E = { TORCH_WALL_OFFSET, 0 }, W = { -TORCH_WALL_OFFSET, 0 },
}

-- Four monster types pulled from four different Freedoom monster slots (see
-- textures/README.md) - real stat variety, not just reskins, so the escalation
-- across levels (weak -> mixed -> dangerous) is felt, not just seen.
local ENEMY_DOT_COLOR = { 0.75, 0.1, 0.65 }
local ENEMY_TYPES = {
	zombie = {
		texturePath = "Interface\\AddOns\\WoWDoom\\textures\\zombie.tga", -- Freedoom POSSA1
		aspect = 41 / 57, scale = 0.85,
		maxHP = 55, speed = 55, contactDPS = 10,
	},
	shotgunguy = {
		texturePath = "Interface\\AddOns\\WoWDoom\\textures\\shotgunguy.tga", -- Freedoom SPOSA1
		aspect = 35 / 55, scale = 0.85,
		maxHP = 90, speed = 65, contactDPS = 16,
	},
	creature = {
		texturePath = "Interface\\AddOns\\WoWDoom\\textures\\creature.tga", -- Freedoom TROOA1
		aspect = 48 / 60, scale = 0.85,
		maxHP = 100, speed = 70, contactDPS = 18,
	},
	demon = {
		texturePath = "Interface\\AddOns\\WoWDoom\\textures\\demon.tga", -- Freedoom SARGA1
		aspect = 38 / 59, scale = 0.9,
		maxHP = 130, speed = 100, contactDPS = 24,
	},
}

local function CreateBillboardVisuals(obj, dotSize)
	obj.tex = play:CreateTexture(nil, "OVERLAY")
	obj.tex:SetTexture(obj.texturePath)
	obj.miniDot = minimap:CreateTexture(nil, "OVERLAY")
	obj.miniDot:SetSize(dotSize, dotSize)
	obj.miniDot:SetColorTexture(obj.color[1], obj.color[2], obj.color[3])
end

local function PositionMiniDot(obj, dotSize)
	obj.miniDot:ClearAllPoints()
	obj.miniDot:SetPoint("TOPLEFT", minimap, "TOPLEFT",
		(obj.x / CELL) * MINI_SCALE - dotSize / 2, -(obj.y / CELL) * MINI_SCALE - dotSize / 2)
end

local function DestroyBillboard(obj)
	obj.tex:Hide()
	obj.miniDot:Hide()
end

local SPRITES = {}
local ENEMIES = {}
local ALL_BILLBOARDS = {}

local function NormalizeAngle(a)
	a = a % (2 * math.pi)
	if a > math.pi then a = a - 2 * math.pi end
	return a
end

local function TryMove(nx, ny)
	-- Each axis is tested against the OTHER axis's current (committed) position,
	-- not the candidate one - decoupling them lets the player slide along a wall
	-- at an inside corner instead of both checks failing together and locking up.
	if not IsWall(nx + PLAYER_RADIUS, playerY) and not IsWall(nx - PLAYER_RADIUS, playerY) then
		playerX = nx
	end
	if not IsWall(playerX, ny + PLAYER_RADIUS) and not IsWall(playerX, ny - PLAYER_RADIUS) then
		playerY = ny
	end
end

local zbuffer = {} -- corrected wall distance per column, for sprite/enemy occlusion
local currentLines = {} -- current level's compiled wall/portal segments; rebuilt by LoadLevel
local currentSectors = {} -- current level's sectors (floor/ceiling per region); rebuilt by LoadLevel
local currentCellSector -- [y][x] (0-indexed) -> sector index or false for wall; rebuilt by LoadLevel

local function GetSectorAt(worldX, worldY)
	local cx, cy = floor(worldX / CELL), floor(worldY / CELL)
	local row = currentCellSector[cy]
	local idx = row and row[cx]
	return idx or 1 -- fall back to sector 1 rather than erroring if just outside the grid
end

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

	local height = min(PLAY_H, (CELL * PLAY_H) / (dist + 1)) * obj.scale
	local width = height * obj.aspect
	obj.tex:SetSize(width, height)
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
	local curY = enemy.y
	if not IsWall(nx + ENEMY_RADIUS, curY) and not IsWall(nx - ENEMY_RADIUS, curY) then
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
			local nx = enemy.x + (dx / dist) * enemy.speed * elapsed
			local ny = enemy.y + (dy / dist) * enemy.speed * elapsed
			TryMoveEnemy(enemy, nx, ny)
		else
			playerHP = playerHP - enemy.contactDPS * elapsed
		end
	end

	PositionMiniDot(enemy, 5)
end

-- ===== Level load: (re)builds the map, minimap, torches, and enemies for a level.
-- Also used to restart the current level on death - one code path for both. =====
local function LoadLevel(index)
	local def = LEVELS[index]
	currentLevelIndex = index

	for _, obj in ipairs(ALL_BILLBOARDS) do DestroyBillboard(obj) end
	ClearArray(SPRITES)
	ClearArray(ENEMIES)
	ClearArray(ALL_BILLBOARDS)

	MAP_W, MAP_H = #def.mapRows[1], #def.mapRows
	MAP = {}
	for y = 1, MAP_H do
		MAP[y] = {}
		for x = 1, MAP_W do
			local ch = def.mapRows[y]:sub(x, x)
			MAP[y][x] = (ch == "1") and 1 or 0
			if ch == "2" then
				levelExitX, levelExitY = (x - 1 + 0.5) * CELL, (y - 1 + 0.5) * CELL
			end
		end
	end
	currentLines, currentSectors, currentCellSector = CompileGridToSectors(def.mapRows)
	RebuildMinimap()
	ceiling:SetColorTexture(unpack(def.ceilingColor))
	floorTex:SetColorTexture(unpack(def.floorColor))
	for _, col in ipairs(columns) do
		for _, layer in ipairs(col.layers) do
			layer.tex:SetTexture(def.wallTexture)
			layer.lastShadeKey = nil -- force a refresh next frame; the texture changed under it
			layer.lastWallXKey = nil
		end
	end

	for _, pos in ipairs(def.torchSpawns) do
		local offset = SIDE_OFFSET[pos[3]]
		local sprite = {
			x = (pos[1] + 0.5) * CELL + offset[1], y = (pos[2] + 0.5) * CELL + offset[2],
			color = TORCH_DOT_COLOR, texturePath = TORCH_TEXTURE,
			aspect = TORCH_ASPECT, scale = TORCH_SCALE,
		}
		CreateBillboardVisuals(sprite, 4)
		PositionMiniDot(sprite, 4)
		tinsert(SPRITES, sprite)
		tinsert(ALL_BILLBOARDS, sprite)
	end

	for _, spawn in ipairs(def.enemySpawns) do
		local etype = ENEMY_TYPES[spawn[3]]
		local enemy = {
			x = (spawn[1] + 0.5) * CELL, y = (spawn[2] + 0.5) * CELL,
			color = ENEMY_DOT_COLOR, texturePath = etype.texturePath,
			aspect = etype.aspect, scale = etype.scale,
			speed = etype.speed, contactDPS = etype.contactDPS,
			hp = etype.maxHP, maxHP = etype.maxHP, dead = false, hitFlash = 0,
		}
		enemy.spawnX, enemy.spawnY = enemy.x, enemy.y
		CreateBillboardVisuals(enemy, 5)
		PositionMiniDot(enemy, 5)
		tinsert(ENEMIES, enemy)
		tinsert(ALL_BILLBOARDS, enemy)
	end

	playerX, playerY = (def.playerStart[1] + 0.5) * CELL, (def.playerStart[2] + 0.5) * CELL
	playerAngle = def.playerStart[3] or 0
	playerSectorIdx = GetSectorAt(playerX, playerY)
	playerHP = PLAYER_MAX_HP
	UpdateHPBar()
	levelText:SetText(("%s (Level %d / %d)"):format(def.name, index, #LEVELS))

	HideOverlay()
	gameState = "playing"
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
		playerSectorIdx = GetSectorAt(playerX, playerY)
	end

	-- Eye height tracks whichever sector the player is currently standing in,
	-- so a raised platform actually raises the camera - otherwise steps would
	-- be visible but wouldn't feel like anything when you walked onto one.
	local eyeZ = currentSectors[playerSectorIdx].floor + EYE_HEIGHT

	local halfFov = FOV / 2
	for i = 1, NUM_COLUMNS do
		local col = columns[i]
		local rayAngle = playerAngle - halfFov + (i - 0.5) * (FOV / NUM_COLUMNS)
		local wallLayers, finalDist = CastRayLines(playerX, playerY, rayAngle, currentLines, currentSectors, playerSectorIdx)
		-- Sprite/enemy occlusion uses the distance to the ultimate solid stop, not
		-- the nearest layer's distance - a riser only covers part of the column's
		-- height, so it shouldn't hide a creature standing in the room beyond/above
		-- it. Our billboards don't yet have their own per-pixel vertical extent
		-- check either, so this is the more sensible approximation of the two.
		zbuffer[i] = finalDist

		-- Each layer's height is computed from ITS OWN true distance (so farther
		-- layers correctly look smaller/compressed), but a layer's SCREEN
		-- POSITION is pinned to sit directly on top of the previous one rather
		-- than computed independently - independent per-layer centering left a
		-- gap (or worse, a disconnected floating slice) wherever the two
		-- distances didn't happen to agree, which is what "still a half wall"
		-- was actually showing: the far room was there, just not lined up
		-- with the riser beneath it.
		local prevTopY = nil
		for l = 1, LAYERS_PER_COLUMN do
			local layer = col.layers[l]
			local w = wallLayers[l]
			if not w then
				if layer.shown then
					layer.tex:Hide()
					layer.shown = false
				end
			else
				if not layer.shown then
					layer.tex:Show()
					layer.shown = true
				end

				local naturalCenterY, wallH = ComputeSlice(w.dist, w.zBottom, w.zTop, eyeZ)
				local centerY = prevTopY and (prevTopY + wallH / 2) or naturalCenterY
				prevTopY = centerY + wallH / 2

				if wallH ~= layer.lastH then
					layer.tex:SetHeight(wallH)
					layer.lastH = wallH
				end
				local centerYKey = floor(centerY * 4)
				if centerYKey ~= layer.lastCenterYKey then
					layer.tex:ClearAllPoints()
					layer.tex:SetPoint("CENTER", play, "BOTTOMLEFT", col.x, centerY)
					layer.lastCenterYKey = centerYKey
				end

				-- Sample a thin vertical strip of the wall texture at the hit point
				-- (the classic raycaster texture-mapping trick), quantized so we're
				-- not calling SetTexCoord for a difference too small to matter.
				local wallXKey = floor(w.wallX * 256)
				if wallXKey ~= layer.lastWallXKey then
					local u = wallXKey / 256
					layer.tex:SetTexCoord(u, u + 0.01, 0, 1)
					layer.lastWallXKey = wallXKey
				end

				local shade = max(0.2, 1 - w.dist / MAX_RENDER_DIST)
				if w.isVertical then shade = shade * 0.7 end
				local shadeKey = floor(shade * 24)
				if shadeKey ~= layer.lastShadeKey then
					layer.tex:SetVertexColor(shade, shade, shade)
					layer.lastShadeKey = shadeKey
				end
			end
		end
	end

	for _, enemy in ipairs(ENEMIES) do
		UpdateEnemyAI(enemy, elapsed)
	end

	if playerHP <= 0 then
		playerHP = 0
		gameState = "dead"
		ShowOverlay("You Died", "Click or press Space to retry")
	else
		local ex, ey = playerX - levelExitX, playerY - levelExitY
		if (ex * ex + ey * ey) ^ 0.5 < EXIT_RADIUS then
			if currentLevelIndex < #LEVELS then
				gameState = "levelcomplete"
				ShowOverlay("Level Complete", "Click or press Space to continue")
			else
				gameState = "won"
				ShowOverlay("You Win", "Click or press Space to play again")
			end
		end
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

-- ===== Shooting & continue (dead/levelcomplete/won all resolve via one input) =====
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

local function HandleContinueOrShoot()
	if gameState == "dead" then
		LoadLevel(currentLevelIndex)
	elseif gameState == "levelcomplete" then
		LoadLevel(currentLevelIndex + 1)
	elseif gameState == "won" then
		LoadLevel(1)
	else
		Shoot()
	end
end

play:SetScript("OnMouseDown", HandleContinueOrShoot)

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
		HandleContinueOrShoot()
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

LoadLevel(1)
