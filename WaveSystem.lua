--[[

	Wave system, enemy types, and scaling
	this script handles the wave system, enemy spawning, and enemy behavior.
	Enemy Types ; Normal, Runner, Tank, Exploder, Boss.
	-syilfre : 11/15/2025
	
]]--

-- services
local PlayersService = game:GetService("Players") -- players service
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- where rigs are at..
local RunService = game:GetService("RunService") -- heartbeat loop
local PathfindingService = game:GetService("PathfindingService") -- pathfinding for enemies
local Debris = game:GetService("Debris") -- debris service..

-- template rigs 
local BaseRig = ReplicatedStorage.TemplateRig :: Model -- default enemy rig
local BossRig = ReplicatedStorage.BossRig :: Model -- boss enemy rig
local TankRig = ReplicatedStorage.TankRig :: Model -- tank enemy rig
local RagdollModule = require(ReplicatedStorage.Ragdoll :: ModuleScript) -- ragdoll module

-- ui remote to announce things to playerss
local UIEvent = ReplicatedStorage:FindFirstChild("UI") :: RemoteEvent?

-- path debug toggle, shows waypoints yea
local ShowPathDebug = false -- set true if u want neon parts to visualize yah

-- type defs
type EnemyState = "Idle" | "Chasing" | "Dead" -- basic enemy states
type WaveState = "Waiting" | "Intermission" | "InWave" -- wave system states
type EnemyKind = "Normal" | "Runner" | "Boss" | "Tank" | "Exploder" -- all enemy kinds
type PathType = typeof(PathfindingService:CreatePath())

type Enemy = {
	Model: Model, -- the actual rig model
	Hum: Humanoid, -- humanoid controlling health/movement
	Root: BasePart, -- humanoid root part for movement/knockback
	State: EnemyState, -- current AI state
	Target: Player?, -- which player this enemy is chasing rn
	LastPath: number, -- last time we computed a path
	LastAttack: number, -- last time we attacked 
	Id: number, -- unique id per enemy
	Kind: EnemyKind, -- what type of enemy this is
	Damage: number, -- how much damage this enemy deals
	KnockbackMult: number, -- knockback multiplier for this enemy

	Path: PathType?, -- path object from PathfindingService
	Waypoints: { PathWaypoint }?, -- list of waypoints to follow
	WaypointIndex: number, -- which waypoint we are currently moving to
	LastTargetPos: Vector3?, -- last target pos when we pathed

	DebugParts: { BasePart }?, -- neon parts used for showing path
	DiedConnection: RBXScriptConnection?, -- for cleaning up the died connection
}

type WaveConfig = {
	baseEnemyCount: number, -- enemies on first wave
	enemyCountGrowth: number, -- how many more enemies per wave
	spawnRadius: number, -- how far from center enemies spawn
	maxWave: number, -- upper safety cap for wave index
	intermissionDuration: number, -- time between waves
}

type WaveMgr = {
	Wave: number, -- current wave number
	State: WaveState, -- current wave state (waiting/intermission/inwave)
	Time: number, -- timer tracking time spent in current state
	Enemies: { Enemy }, -- list of enemies for current wave
	BossInterval: number, -- how often bosses show up
	NextBossWave: number, -- next wave index that will have a boss
}

-- config for everything, wave, enemy types
local cfg = {
	Wave = {
		baseEnemyCount = 3, -- enemies on wave 1
		enemyCountGrowth = 2, -- +2 enemies per wave
		spawnRadius = 45, -- radius of spawn circle around the center
		maxWave = 999, -- just a big cap so it doesn't go crazy
		intermissionDuration = 6, -- seconds between waves
	} :: WaveConfig,
	Enemy = {
		walkSpeed = 14, -- default walkspeed before multipliers
		health = 50, -- default hp
		damage = 10, -- base melee damage
		attackRange = 4, -- max distance to swing at player
		attackCooldown = 1, -- seconds between attacks
		pathRecomputeDelay = .6, -- min seconds before we recompute path
		repathDistance = 4, -- how far target has to move to trigger new path
		knockbackForce = 70, -- horizontal kb force
		knockbackUp = 25, -- vertical kb force
		waypointReachDist = 4, -- how close we need to be to a waypoint to move on
		Types = {
			Normal = { -- base/default enemy
				healthMult = 1, -- normal hp
				speedMult = 1, -- normal speed
				damageMult = 1, -- normal damage
				knockbackMult = 1, -- default knockback
			},
			Runner = {
				healthMult = .75, -- a bit squishier
				speedMult = 1.2, -- faster
				speedAdd = 8, -- flat bonus speed
				damageMult = 1, -- same damage as base
				knockbackMult = 1, -- normal kb
			},
			Tank = {
				healthMult = 2.5, -- chunky
				speedMult = .6, -- slow
				damageMult = 1.75, -- hurts more
				knockbackMult = .5, -- less kb on players
			},
			Boss = {
				healthMult = 3.5, -- huge hp
				speedMult = .75, -- a bit slower
				damageMult = 2, -- big dmg
				knockbackMult = 1.4, -- extra kb
			},
			Exploder = {
				healthMult = .8, -- kinda squishy
				speedMult = 1.1, -- slightly faster
				damageMult = 1, -- normal base dmg
				knockbackMult = 1.1, -- a bit more kb
				blastRadius = 12, -- explosion radius
				explosionDamageFactor = 1.5, -- explosion dmg = base dmg * this
			},
		},
	},
	Misc = {
		minPlayers = 1, -- at least 1 player to start waves
	},
}

-- runner chance scales but is capped so not all are runnerss
local function GetRunnerChancePercent(wave: number): number
	local base = 10 -- 10% on wave 1
	local extra = (wave - 1) * 2 -- +2% per extra wave
	local cap = 60 -- hard cap
	local value = base + extra
	if value > cap then
		value = cap -- clamp
	end
	return value
end

local EnemyClass = {} 
EnemyClass.__index = EnemyClass

local WaveClass = {} 
WaveClass.__index = WaveClass

local Waves: WaveMgr? = nil -- holds the active wave manager
local nextEnemyId = 1 -- simple id tracker per enemy

-- collision

-- puts every BasePart inside a model in a collision group
local function SetModelCollisionGroup(model: Model, groupName: string)
	for _, descendant in ipairs(model:GetDescendants()) do -- loop through all descendants
		if descendant:IsA("BasePart") then -- check if the object is a BasePart
			descendant.CollisionGroup = groupName -- assign the collision group
		end
	end
end

-- UI local functions, keep things tidyyyyyyyyy

local function SendWaveText(text: string)
	if UIEvent then -- only if UI remote exists
		UIEvent:FireAllClients("WaveText", text) -- tell clients to update the wave text
	end
end

local function SendInfoText(text: string)
	if UIEvent then
		UIEvent:FireAllClients("InfoText", {
			mode = "set", -- set text instantly
			text = text,
		})
	end
end

local function SendFadeInfo(text: string, duration: number)
	if UIEvent then
		UIEvent:FireAllClients("InfoText", {
			mode = "fade", -- show then fade out
			text = text,
			duration = duration, -- how long till it fades
		})
	end
end

local function SendBossInfo(nextBoss: number)
	if UIEvent then
		UIEvent:FireAllClients("BossInfo", {
			nextBoss = nextBoss, -- which wave the next boss is at
		})
	end
end

-- local functions

-- grabs only players that have a character + alive humanoid
local function GetAlivePlayers(): { Player }
	local out: { Player } = {} -- output list
	for _, plr in ipairs(PlayersService:GetPlayers()) do -- loop all players
		local char = plr.Character -- player character model
		local hum = char and char:FindFirstChildOfClass("Humanoid") -- find humanoid
		if hum and hum.Health > 0 then -- humanoid exists and is alive
			table.insert(out, plr) -- keep this player
		end
	end
	return out
end

-- center of the arena 
local function GetCenter(): Vector3
	return Vector3.new(0, 3, 0) -- x/y/z
end

-- random cf in radius
local function GetSpawnCF(): CFrame
	local center = GetCenter() -- middle of the arena
	local r = cfg.Wave.spawnRadius -- spawn radius
	local ang = math.random() * math.pi * 2 -- random angle from 0 to 2pi (or circle lol)
	local off = Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r) -- position on the circle
	local pos = center + off + Vector3.new(0, 2, 0) -- spawn a bit above ground
	return CFrame.new(pos, center) -- face the center
end

-- knockback using BodyVelocity, pushes away from "from" position
local function Knockback(root: BasePart, from: Vector3, mult: number)
	local dir = (root.Position - from) -- vector from explosion/hit to target
	if dir.Magnitude < .1 then -- avoid weird 0-length vector
		dir = Vector3.new(0, 1, 0) -- default direction upwards
	else
		dir = dir.Unit -- normalize to length 1
	end

	-- flatten so we don't tilt them weirdly (remove y)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < .1 then
		flat = Vector3.new(0, 0, 1) -- fallback direction
	else
		flat = flat.Unit -- normalize
	end

	-- sideways push + upward push scaled by mult
	local v = flat * (cfg.Enemy.knockbackForce * mult) -- horizontal force
	v += Vector3.new(0, cfg.Enemy.knockbackUp * mult, 0) -- vertical force

	local bv = Instance.new("BodyVelocity") -- body mover for kb
	bv.MaxForce = Vector3.new(1e5, 1e5, 1e5) -- allow it to actually move them
	bv.Velocity = v -- final kb vector
	bv.Parent = root -- attach to root part
	Debris:AddItem(bv, .25) -- auto clean after a bit
end

-- pick the closest alive player to this enemy
local function GetNearestPlayer(enemy: Enemy): Player?
	local best: Player? = nil -- best player so far
	local bestDist = math.huge -- start with huge distance
	local pos = enemy.Root.Position -- enemy position

	for _, plr in ipairs(GetAlivePlayers()) do -- loop all alive players
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then -- make sure we have a root part
			local d = (root.Position - pos).Magnitude -- distance between enemy and player
			if d < bestDist then -- found closer one
				bestDist = d
				best = plr
			end
		end
	end

	return best
end

-- enemy

function EnemyClass:ClearDebugPath()
	local parts = self.DebugParts
	if not parts then
		return
	end

	-- remove each path debug part
	for _, part in ipairs(parts) do
		if part and part.Parent then
			part:Destroy()
		end
	end
	self.DebugParts = nil -- clear reference
end

-- draws the path if debug is on, using parts.
function EnemyClass:ShowPath(path: PathType)
	self:ClearDebugPath() -- clear previous debug parts first
	if not ShowPathDebug then
		return -- bail if debug is disabled
	end

	local waypoints = path:GetWaypoints() -- get all waypoints from path
	local parts: { BasePart } = {} -- store all debug parts

	for _, wp in ipairs(waypoints) do -- loop every waypoint
		local node = Instance.new("Part") -- small neon part
		node.Name = "PathNode"
		node.Anchored = true
		node.CanCollide = false
		node.Size = Vector3.new(.6, .6, .6)
		node.Material = Enum.Material.Neon

		if wp.Action == Enum.PathWaypointAction.Jump then
			node.Color = Color3.fromRGB(255, 0, 0) -- red for jump nodes
		else
			node.Color = Color3.fromRGB(0, 255, 0) -- green for normal nodes
		end

		node.CFrame = CFrame.new(wp.Position) -- place at waypoint
		node.Parent = workspace -- put into world
		table.insert(parts, node)
	end

	self.DebugParts = parts -- for cleanup
end

-- spawns 1 enemy of a given type at a given cframe
function EnemyClass.new(cf: CFrame, kind: EnemyKind): Enemy
	local rigModel: Model

	-- pick rig based on kind
	if kind == "Boss" then
		rigModel = BossRig:Clone()
	elseif kind == "Tank" then
		rigModel = TankRig:Clone()
	else
		rigModel = BaseRig:Clone()
	end

	local model = rigModel

	-- give it a name depending on the type ya
	if kind == "Boss" then
		model.Name = "Boss"
	elseif kind == "Runner" then
		model.Name = "Runner"
	elseif kind == "Tank" then
		model.Name = "Tank"
	elseif kind == "Exploder" then
		model.Name = "Exploder"
	else
		model.Name = "Enemy"
	end

	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid

	model.PrimaryPart = root -- set primary part
	model:SetPrimaryPartCFrame(cf) -- position + face towards center
	model.Parent = workspace -- actually spawn it

	-- set enemy collisions
	SetModelCollisionGroup(model, "NPC")

	-- base stats
	local baseSpeed = cfg.Enemy.walkSpeed
	local baseHealth = cfg.Enemy.health
	local baseDamage = cfg.Enemy.damage

	-- type multipliers
	local typeCfg = cfg.Enemy.Types[kind] or cfg.Enemy.Types.Normal

	local speedMult = typeCfg.speedMult or 1
	local speedAdd = typeCfg.speedAdd or 0
	local healthMult = typeCfg.healthMult or 1
	local damageMult = typeCfg.damageMult or 1
	local knockMult = typeCfg.knockbackMult or 1

	-- final stats
	local speed = baseSpeed * speedMult + speedAdd -- base*mult + bonus
	local health = baseHealth * healthMult
	local damage = baseDamage * damageMult

	hum.WalkSpeed = speed -- set movement speed
	hum.MaxHealth = health -- set max hp
	hum.Health = health -- set current hp
	hum.BreakJointsOnDeath = false -- we ragdoll instead of classic death

	-- little visual changes per type
	if kind == "Runner" then
		local head = model:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			local decal = head:FindFirstChildOfClass("Decal")
			if not decal then
				decal = Instance.new("Decal") -- create face decal
				decal.Name = "face"
				decal.Face = Enum.NormalId.Front
				decal.Parent = head
			end
			decal.Texture = "rbxassetid://9619557575" -- runner face
		end

		local torso = model:FindFirstChild("Torso") :: BasePart?
		if torso then
			torso.BrickColor = BrickColor.new("Bright bluish green") -- teal-ish
		end
	elseif kind == "Exploder" then
		local torso = model:FindFirstChild("Torso") :: BasePart?
		if torso then
			torso.BrickColor = BrickColor.new("Bright red") -- red torso
		end
	end

	local id = nextEnemyId -- assign id
	nextEnemyId += 1 -- prepare next id

	-- make our enemy table
	local self = setmetatable({}, EnemyClass) :: Enemy
	self.Model = model
	self.Hum = hum
	self.Root = root
	self.State = "Idle"
	self.Target = nil
	self.LastPath = 0
	self.LastAttack = 0
	self.Id = id
	self.Kind = kind
	self.Damage = damage
	self.KnockbackMult = knockMult
	self.Path = nil
	self.Waypoints = nil
	self.WaypointIndex = 0
	self.LastTargetPos = nil
	self.DebugParts = nil
	self.DiedConnection = nil

	-- death behavior, handles exploder and ragdoll
	self.DiedConnection = hum.Died:Connect(function() -- runs when humanoid hits 0 hp
		self.State = "Dead"
		self:ClearDebugPath() -- remove path parts

		-- exploder enemies explode on death
		if self.Kind == "Exploder" then
			EnemyClass.Explode(self) -- explode right away
		end

		-- ragdoll the model
		if self.Model then
			RagdollModule:Ragdoll(self.Model)
		end
	end)

	return self
end

-- for exploder class; makes an explosion instance anddd blows em up also applies knockback.
function EnemyClass:Explode()
	local model = self.Model :: Model?
	if not model then
		return -- enemy already gone
	end

	-- primary part
	local originPart = model.PrimaryPart :: BasePart

	local typeCfg = cfg.Enemy.Types[self.Kind] or cfg.Enemy.Types.Exploder
	local radius = typeCfg.blastRadius or 12 -- explosion size
	local factor = typeCfg.explosionDamageFactor or 1.5
	local explosionDamage = self.Damage * factor -- scale from base damage

	local e = Instance.new("Explosion")
	e.Position = originPart.Position -- where it explodes
	e.BlastRadius = radius
	e.BlastPressure = 0 -- no default roblox knockback
	e.DestroyJointRadiusPercent = 0 -- don't auto-break joints

	local hitChars: { [Model]: boolean } = {} -- track which characters we already hit

	-- damage + knockback for anything we hit
	e.Hit:Connect(function(part)
		if not part or not part.Parent then
			return
		end

		local char = part:FindFirstAncestorOfClass("Model") -- go up to the model
		if not char or hitChars[char] then
			return -- no char or already damaged this char
		end
		hitChars[char] = true -- mark as hit

		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			hum:TakeDamage(explosionDamage) -- apply explosion damage
		end

		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			Knockback(hrp, originPart.Position, self.KnockbackMult + .5) -- extra kb for explode
		end
	end)

	-- parent so the explosion actually exists in the world
	e.Parent = originPart
end

function EnemyClass:Destroy()
	self.State = "Dead"
	self:ClearDebugPath()

	-- disconnect died connection
	if self.DiedConnection then
		self.DiedConnection:Disconnect()
		self.DiedConnection = nil
	end

	if self.Model and self.Model.Parent then
		self.Model:Destroy()
	end
end

-- base attack: checks distance, cooldown, then hits + knockback
function EnemyClass:TryAttack(now: number)
	local targetPlayer = self.Target
	if not targetPlayer then
		return
	end

	local char = targetPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not hum or not root or hum.Health <= 0 then
		return -- target dead or invalid
	end

	local d = (root.Position - self.Root.Position).Magnitude -- distance to target
	if d > cfg.Enemy.attackRange then
		return -- too far to hit
	end

	if now - self.LastAttack < cfg.Enemy.attackCooldown then
		return -- still on cooldown
	end

	self.LastAttack = now -- mark last attack time

	hum:TakeDamage(self.Damage) -- do dmg

	local hitSound = Instance.new("Sound")
	hitSound.SoundId = "rbxassetid://8595975458" -- hit sfx
	hitSound.Volume = 1
	hitSound.Parent = root
	hitSound:Play()
	Debris:AddItem(hitSound, 2) -- clean up sound after 2s

	Knockback(root, self.Root.Position, self.KnockbackMult) -- knock player back
end

-- build a path from enemy to target
function EnemyClass:ComputePath(targetPos: Vector3, now: number)
	self.LastPath = now -- remember when we last computed
	self.LastTargetPos = targetPos -- remember where the target was

	local path = PathfindingService:CreatePath() -- create a new path object
	path:ComputeAsync(self.Root.Position, targetPos) -- ask roblox to compute path

	if path.Status ~= Enum.PathStatus.Success then -- path failed
		self.Path = nil
		self.Waypoints = nil
		self.WaypointIndex = 0
		self:ClearDebugPath()
		return
	end

	local waypoints = path:GetWaypoints()
	if #waypoints == 0 then -- no waypoints means nothing to follow
		self.Path = nil
		self.Waypoints = nil
		self.WaypointIndex = 0
		self:ClearDebugPath()
		return
	end

	self.Path = path
	self.Waypoints = waypoints
	self.WaypointIndex = (#waypoints >= 2) and 2 or 1 -- skip the first wp usually
	self:ShowPath(path) -- draw debug if enabled
end

-- see if we need to refresh the path based on time or how far target moved
function EnemyClass:UpdatePath(now: number, targetPos: Vector3)
	local needNew = false

	if not self.Path or not self.Waypoints or self.WaypointIndex == 0 or self.WaypointIndex > #self.Waypoints then
		-- no path or we're out of bounds
		needNew = true
	else
		--- save performance by only recalculating the path if enough time has passed, or the target has moved far enoughh.
		if now - self.LastPath >= cfg.Enemy.pathRecomputeDelay then
			local last = self.LastTargetPos
			if not last or (targetPos - last).Magnitude >= cfg.Enemy.repathDistance then
				needNew = true
			end
		end
	end

	if needNew then
		self:ComputePath(targetPos, now)
	end
end

-- follow waypoints and move towards the player / last target pos
function EnemyClass:FollowPath(targetPos: Vector3)
	local waypoints = self.Waypoints
	if not waypoints or #waypoints == 0 then
		self.Hum:MoveTo(targetPos) -- just run at target
		return
	end

	local index = self.WaypointIndex
	if index < 1 then
		index = 1
		self.WaypointIndex = 1
	end

	if index > #waypoints then
		self.Hum:MoveTo(targetPos)
		return
	end

	local root = self.Root
	local wp = waypoints[index]

	-- flatten waypoint position to the enemy's current Y 
	local wpPosFlat = Vector3.new(wp.Position.X, root.Position.Y, wp.Position.Z)
	local dist = (wpPosFlat - root.Position).Magnitude

	if dist < cfg.Enemy.waypointReachDist then -- if close enough, go to next waypoint
		index += 1
		self.WaypointIndex = index
		if index > #waypoints then
			self.Hum:MoveTo(targetPos)
			return
		end
		wp = waypoints[index]
		wpPosFlat = Vector3.new(wp.Position.X, root.Position.Y, wp.Position.Z)
	end

	if wp.Action == Enum.PathWaypointAction.Jump then
		self.Hum.Jump = true -- tell humanoid to jump for this waypoint
	end

	self.Hum:MoveTo(wpPosFlat) -- move to waypoint
end

-- main enemy update per frame
function EnemyClass:Step(_dt: number, now: number)
	if self.State == "Dead" then
		return -- dead enemies don't do anything
	end

	local targetPlayer = self.Target
	local char = targetPlayer and targetPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	-- if current target is gone / dead, try to find another player
	if not targetPlayer or not char or not root or not hum or hum.Health <= 0 then
		self.Target = GetNearestPlayer(self) -- pick nearest alive player
		targetPlayer = self.Target
		char = targetPlayer and targetPlayer.Character
		root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		hum = char and char:FindFirstChildOfClass("Humanoid")

		if not targetPlayer or not char or not root or not hum or hum.Health <= 0 then
			-- no valid target at all, just idle
			self.State = "Idle"
			self.Hum:MoveTo(self.Root.Position) -- stand still basically
			return
		end
	end

	if self.State == "Idle" then
		self.State = "Chasing" -- start chasing when we have a target
	end

	self:UpdatePath(now, root.Position) -- maybe recompute path
	self:FollowPath(root.Position) -- follow current path towards target
	self:TryAttack(now) -- try to attack if close enough
end

-- waves

-- returns true if all enemies in this list are dead
local function AllDead(list: { Enemy }): boolean
	for _, enemy in ipairs(list) do
		if enemy.State ~= "Dead" then
			return false
		end
	end
	return true
end

local function BroadcastBossInfo()
	local w = Waves
	if not w then
		return
	end
	SendBossInfo(w.NextBossWave)
end

-- basic wave manager, tracks current wave and enemies
function WaveClass.new(): WaveMgr
	local self = setmetatable({}, WaveClass) :: WaveMgr
	self.Wave = 0 -- current wave
	self.State = "Waiting" -- start waiting for players
	self.Time = 0 -- timer for current state
	self.Enemies = {} -- list of enemies in current wave
	self.BossInterval = 3 -- first boss at wave 3
	self.NextBossWave = 3 -- track which wave next boss will spawn
	return self
end

-- how many enemies to spawn this wave
function WaveClass:GetEnemyCount(): number
	local base = cfg.Wave.baseEnemyCount
	local grow = cfg.Wave.enemyCountGrowth
	return base + grow * self.Wave -- simple linear scaling
end

function WaveClass:ClearEnemies()
	for _, enemy in ipairs(self.Enemies) do
		enemy:Destroy() -- clean up enemy model + connections
	end
	table.clear(self.Enemies) -- wipe table
end

-- starts a new wave and spawns enemies
function WaveClass:SpawnWave()
	self.Wave += 1 -- go to next wave
	if self.Wave > cfg.Wave.maxWave then
		self.Wave = 1 -- loop back just in case
	end

	self.State = "InWave" -- we are now in wave
	self.Time = 0 -- reset timer

	local total = self:GetEnemyCount() -- how many enemies to spawn
	local isBossWave = (self.Wave == self.NextBossWave) -- boss check

	SendWaveText(string.format("Wave %d", self.Wave))

	if isBossWave then
		SendInfoText("Boss wave! Survive this round.")
	else
		SendInfoText("Enemies incoming.")
	end

	local remaining = total -- enemies left to spawn this wave

	-- drop in a boss on boss waves, then push next boss wave further
	if isBossWave then
		local bossCf = GetSpawnCF() -- random spawn around center
		local bossEnemy = EnemyClass.new(bossCf, "Boss")
		table.insert(self.Enemies, bossEnemy)
		remaining -= 1

		self.BossInterval += 1 -- bosses become more spaced out over time
		self.NextBossWave = self.Wave + self.BossInterval
		BroadcastBossInfo()
	end

	local runnerChancePercent = GetRunnerChancePercent(self.Wave) -- wave-based runner chance
	local tankChancePercent = 10 -- flat 10% tank
	local exploderChancePercent = 12 -- flat 12% exploder

	-- roll type for each remaining enemy
	for _ = 1, math.max(0, remaining) do
		local kind: EnemyKind = "Normal"
		local roll = math.random(1, 100) -- random number between 1 and 100

		if roll <= tankChancePercent then
			kind = "Tank"
		elseif roll <= tankChancePercent + runnerChancePercent then
			kind = "Runner"
		elseif roll <= tankChancePercent + runnerChancePercent + exploderChancePercent then
			kind = "Exploder"
		end

		local cf = GetSpawnCF() -- random spawn location
		local enemy = EnemyClass.new(cf, kind) -- create enemy
		table.insert(self.Enemies, enemy) -- track it
	end
end

-- actual wave loop, waiting > intermission > in wave and loop againn
function WaveClass:Update(dt: number)
	self.Time += dt -- tick timer

	local alivePlayers = GetAlivePlayers() -- get all alive players
	if #alivePlayers < cfg.Misc.minPlayers then
		-- not enough players, reset to waiting
		if self.State ~= "Waiting" then
			self.State = "Waiting"
			self.Time = 0
			self.Wave = 0
			self:ClearEnemies()
			SendWaveText("Waiting for players...")
			SendInfoText("At least one player required to start.")
		end
		return
	end

	-- first time we see enough players, go into intermission
	if self.State == "Waiting" then
		self.State = "Intermission"
		self.Time = 0
		SendWaveText("Intermission")
		SendInfoText("Players joined. Next wave starting soon.")
		BroadcastBossInfo()
		return
	end

	if self.State == "Intermission" then
		local remain = math.max(0, math.floor(cfg.Wave.intermissionDuration - self.Time)) -- seconds left
		SendInfoText(string.format("Next wave in %d second(s)...", remain))
		if self.Time >= cfg.Wave.intermissionDuration then
			self:SpawnWave() -- start next wave
		end
		return
	end

	if self.State == "InWave" then
		local now = os.clock() -- current time for cooldowns / pathing

		for _, enemy in ipairs(self.Enemies) do
			enemy:Step(dt, now) -- update each enemy
		end

		-- if everyone is dead, reset back to waiting
		if #GetAlivePlayers() == 0 then
			self.State = "Waiting"
			self.Time = 0
			self.Wave = 0
			SendWaveText("Waiting for players...")
			SendInfoText("All players down. Waiting for new players.")
			self:ClearEnemies()
			return
		end

		-- all enemies dead, go back to intermission for next wave
		if AllDead(self.Enemies) then
			SendFadeInfo("Wave cleared!", 1.5)
			self.State = "Intermission"
			self.Time = 0

			-- lil delay to make enemy bodies linger for a bit longer before cleanup
			task.delay(2, WaveClass.ClearEnemies, self)

			SendWaveText("Intermission")
			return
		end
	end
end

-- players

-- collision group setting & announcement when a player dies
local function OnCharAdded(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		SetModelCollisionGroup(char, "Players") -- make sure player parts use Players collision group

		hum.Died:Connect(function()
			SendInfoText("A player has fallen...") -- small flavor message
		end)
	end
end

local function OnPlayerAdded(plr: Player)
	plr.CharacterAdded:Connect(OnCharAdded) -- hook character spawn
	BroadcastBossInfo() -- resend next boss info to this player
end

local function OnPlayerRemoving(_plr: Player)
	if not Waves then
		return
	end

	-- if this was the last player, hard reset waves
	if #PlayersService:GetPlayers() <= 1 then
		Waves:ClearEnemies()
		Waves.State = "Waiting"
		Waves.Time = 0
		Waves.Wave = 0
		SendWaveText("Waiting for players...")
		SendInfoText("Waiting for players...")
	end
end

-- init

math.randomseed(os.time()) -- seed random so rolls arent the same every server boot :v
Waves = WaveClass.new()
BroadcastBossInfo()

PlayersService.PlayerAdded:Connect(OnPlayerAdded)
PlayersService.PlayerRemoving:Connect(OnPlayerRemoving)

for _, plr in ipairs(PlayersService:GetPlayers()) do
	OnPlayerAdded(plr) -- in case script runs after some players already exist
end

RunService.Heartbeat:Connect(function(dt: number)
	local w = Waves
	if w then
		w:Update(dt) -- main loop tick
	end
end)
