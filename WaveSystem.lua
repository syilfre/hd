--[[

	Wave system, enemy types, and scaling
	this script handles the wave system, enemy spawning, and enemy behavior.
	Enemy Types ; Normal, Runner, Tank, Exploder, Boss.
	-syilfre : 11/15/2025
	
]]--

-- services
local P = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunS = game:GetService("RunService")
local PathS = game:GetService("PathfindingService")
local DBR = game:GetService("Debris")

-- template rigs
local BaseRig = RS.TemplateRig :: Model
local BossRig = RS.BossRig :: Model
local TankRig = RS.TankRig :: Model
local RagdollModule = require(RS.Ragdoll :: ModuleScript)

local UIEvent = RS:FindFirstChild("UI") :: RemoteEvent?

-- path debug toggle, shows waypoints yea
local ShowPathDebug = false

-- type defs
type EnemyState = "Idle" | "Chasing" | "Dead"
type WaveState = "Waiting" | "Intermission" | "InWave"
type EnemyKind = "Normal" | "Runner" | "Boss" | "Tank" | "Exploder"
type PathType = typeof(PathS:CreatePath())

type Enemy = {
	Model: Model,
	Hum: Humanoid,
	Root: BasePart,
	State: EnemyState,
	Target: Player?,
	LastPath: number,
	LastAttack: number,
	Id: number,
	Kind: EnemyKind,
	Damage: number,
	KnockbackMult: number,

	Path: PathType?,
	Waypoints: { PathWaypoint }?,
	WaypointIndex: number,
	LastTargetPos: Vector3?,

	DebugParts: { BasePart }?,
}

type WaveConfig = {
	baseEnemyCount: number,
	enemyCountGrowth: number,
	spawnRadius: number,
	maxWave: number,
	intermissionDuration: number,
}

type WaveMgr = {
	Wave: number,
	State: WaveState,
	Time: number,
	Enemies: { Enemy },
	BossInterval: number,
	NextBossWave: number,
}

-- config for everything, wave, enemy types
local cfg = {
	Wave = {
		baseEnemyCount = 3,
		enemyCountGrowth = 2,
		spawnRadius = 45,
		maxWave = 999,
		intermissionDuration = 6,
	} :: WaveConfig,
	Enemy = {
		walkSpeed = 14,
		health = 50,
		damage = 10,
		attackRange = 4,
		attackCooldown = 1,
		pathRecomputeDelay = .6,
		repathDistance = 4,
		knockbackForce = 70,
		knockbackUp = 25,
		waypointReachDist = 4,
		Types = {
			Normal = {
				healthMult = 1,
				speedMult = 1,
				damageMult = 1,
				knockbackMult = 1,
			},
			Runner = {
				healthMult = .75,
				speedMult = 1.2,
				speedAdd = 8,
				damageMult = 1,
				knockbackMult = 1,
			},
			Tank = {
				healthMult = 2.5,
				speedMult = .6,
				damageMult = 1.75,
				knockbackMult = .5,
			},
			Boss = {
				healthMult = 3.5,
				speedMult = .75,
				damageMult = 2,
				knockbackMult = 1.4,
			},
			Exploder = {
				healthMult = .8,
				speedMult = 1.1,
				damageMult = 1,
				knockbackMult = 1.1,
				blastRadius = 12,
				explosionDamageFactor = 1.5,
			},
		},
	},
	Misc = {
		minPlayers = 1,
	},
}

-- runner chance & scales but also capped so it doesn't make all enemies runners
local function GetRunnerChancePercent(wave: number): number
	local base = 10 -- 10 on wave 1
	local extra = (wave - 1) * 2 -- +2 per wave
	local cap = 60 -- max 60
	local value = base + extra
	if value > cap then
		value = cap
	end
	return value
end

local EnemyClass = {}
EnemyClass.__index = EnemyClass

local WaveClass = {}
WaveClass.__index = WaveClass

local Waves: WaveMgr? = nil
local nextEnemyId = 1 -- simple id tracker per enemy

-- collision

-- puts every BasePart inside a model in a collision group
local function SetModelCollisionGroup(model: Model, groupName: string)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CollisionGroup = groupName
		end
	end
end

-- UI local functions, keep things tidyyyyyyyyy

local function SendWaveText(text: string)
	if UIEvent then
		UIEvent:FireAllClients("WaveText", text)
	end
end

local function SendInfoText(text: string)
	if UIEvent then
		UIEvent:FireAllClients("InfoText", {
			mode = "set",
			text = text,
		})
	end
end

local function SendFadeInfo(text: string, duration: number)
	if UIEvent then
		UIEvent:FireAllClients("InfoText", {
			mode = "fade",
			text = text,
			duration = duration,
		})
	end
end

local function SendBossInfo(nextBoss: number)
	if UIEvent then
		UIEvent:FireAllClients("BossInfo", {
			nextBoss = nextBoss,
		})
	end
end

-- local functions

-- grabs only players that have a character + alive humanoid
local function GetAlivePlayers(): { Player }
	local out: { Player } = {}
	for _, plr in ipairs(P:GetPlayers()) do
		local c = plr.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 then
			table.insert(out, plr)
		end
	end
	return out
end

-- center of the arena
local function GetCenter(): Vector3
	return Vector3.new(0, 3, 0)
end

-- random cf in radius
local function GetSpawnCF(): CFrame
	local center = GetCenter()
	local r = cfg.Wave.spawnRadius
	local ang = math.random() * math.pi * 2 -- random angle from 0 to 2pi (or circle lol)
	local off = Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r)
	local pos = center + off + Vector3.new(0, 2, 0) -- spawn a bit above ground
	return CFrame.new(pos, center) -- face the center
end

-- knockback using BodyVelocity, pushes away from "from" position
local function Knockback(root: BasePart, from: Vector3, mult: number)
	local dir = (root.Position - from)
	if dir.Magnitude < .1 then
		-- avoid weird 0-length vector
		dir = Vector3.new(0, 1, 0)
	else
		dir = dir.Unit
	end

	-- flatten so we don't tilt them weirdly
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < .1 then
		flat = Vector3.new(0, 0, 1)
	else
		flat = flat.Unit
	end

	-- sideways push + upward push scaled by mult
	local v = flat * (cfg.Enemy.knockbackForce * mult)
	v += Vector3.new(0, cfg.Enemy.knockbackUp * mult, 0)

	local bv = Instance.new("BodyVelocity")
	bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
	bv.Velocity = v
	bv.Parent = root
	DBR:AddItem(bv, .25) -- auto clean after a bit
end

-- pick the closest alive player to this enemy
local function GetNearestPlayer(enemy: Enemy): Player?
	local best: Player? = nil
	local bestDist = math.huge
	local pos = enemy.Root.Position

	for _, plr in ipairs(GetAlivePlayers()) do
		local c = plr.Character
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local d = (root.Position - pos).Magnitude
			if d < bestDist then
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
	for _, p in ipairs(parts) do
		if p and p.Parent then
			p:Destroy()
		end
	end
	self.DebugParts = nil
end

-- draws the path if debug is on, using parts.
function EnemyClass:ShowPath(path: PathType)
	self:ClearDebugPath()
	if not ShowPathDebug then
		return
	end

	local wps = path:GetWaypoints()
	local parts: { BasePart } = {}
	for _, wp in ipairs(wps) do
		local part = Instance.new("Part")
		part.Name = "PathNode"
		part.Anchored = true
		part.CanCollide = false
		part.Size = Vector3.new(.6, .6, .6)
		part.Material = Enum.Material.Neon
		if wp.Action == Enum.PathWaypointAction.Jump then
			part.Color = Color3.fromRGB(255, 0, 0)
		else
			part.Color = Color3.fromRGB(0, 255, 0)
		end
		part.CFrame = CFrame.new(wp.Position)
		part.Parent = workspace
		table.insert(parts, part)
	end
	self.DebugParts = parts
end

-- spawns 1 enemy of a given type at a given cframe
function EnemyClass.new(cf: CFrame, kind: EnemyKind): Enemy
	local rigModel: Model
	if kind == "Boss" then
		rigModel = BossRig:Clone()
	elseif kind == "Tank" then
		rigModel = TankRig:Clone()
	else
		rigModel = BaseRig:Clone()
	end

	local m = rigModel

	-- give it a name depending on the type ya
	if kind == "Boss" then
		m.Name = "Boss"
	elseif kind == "Runner" then
		m.Name = "Runner"
	elseif kind == "Tank" then
		m.Name = "Tank"
	elseif kind == "Exploder" then
		m.Name = "Exploder"
	else
		m.Name = "Enemy"
	end

	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = m:FindFirstChildOfClass("Humanoid")

	m.PrimaryPart = root
	m:SetPrimaryPartCFrame(cf)
	m.Parent = workspace

	-- enemies colliding in their own group
	SetModelCollisionGroup(m, "NPC")

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
	local speed = baseSpeed * speedMult + speedAdd
	local health = baseHealth * healthMult
	local damage = baseDamage * damageMult

	hum.WalkSpeed = speed
	hum.MaxHealth = health
	hum.Health = health
	hum.BreakJointsOnDeath = false -- we ragdoll instead

	-- little visual changes per type
	if kind == "Runner" then
		local head = m:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			local decal = head:FindFirstChildOfClass("Decal")
			if not decal then
				decal = Instance.new("Decal")
				decal.Name = "face"
				decal.Face = Enum.NormalId.Front
				decal.Parent = head
			end
			decal.Texture = "rbxassetid://9619557575"
		end

		local torso = m:FindFirstChild("Torso") :: BasePart?
		if torso then
			torso.BrickColor = BrickColor.new("Bright bluish green")
		end
	elseif kind == "Exploder" then
		local torso = m:FindFirstChild("Torso") :: BasePart?
		if torso then
			torso.BrickColor = BrickColor.new("Bright red")
		end
	end

	local id = nextEnemyId
	nextEnemyId += 1

	-- make our enemy table
	local self = setmetatable({}, EnemyClass) :: Enemy
	self.Model = m
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

	-- death behavior, handles exploder and ragdoll
	hum.Died:Connect(function()
		self.State = "Dead"
		self:ClearDebugPath()

		if self.Kind == "Exploder" then
			task.spawn(function()
				pcall(function()
					EnemyClass.Explode(self)
				end)
			end)
		end

		task.spawn(function()
			pcall(function()
				RagdollModule:Ragdoll(self.Model)
			end)
		end)
	end)

	return self
end

-- for exploder class; makes an explosion instance anddd blows em up also applies knockback.
function EnemyClass:Explode()
	local m = self.Model :: Model?
	if not m then
		return
	end

	-- primarypart is set in EnemyClass.new
	local originPart = m.PrimaryPart :: BasePart

	local typeCfg = cfg.Enemy.Types[self.Kind] or cfg.Enemy.Types.Exploder
	local radius = typeCfg.blastRadius or 12
	local factor = typeCfg.explosionDamageFactor or 1.5
	local explosionDamage = self.Damage * factor

	local ea = Instance.new("Explosion")
	ea.Position = originPart.Position
	ea.BlastRadius = radius
	ea.BlastPressure = 0 -- no default roblox knockback
	ea.DestroyJointRadiusPercent = 0

	local hitChars: { [Model]: boolean } = {}

	-- damage + knockback for anything we hit
	ea.Hit:Connect(function(part)
		if not part or not part.Parent then
			return
		end

		local char = part:FindFirstAncestorOfClass("Model")
		if not char or hitChars[char] then
			return
		end
		hitChars[char] = true

		local h = char:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 then
			h:TakeDamage(explosionDamage)
		end

		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			Knockback(hrp, originPart.Position, self.KnockbackMult + .5)
		end
	end)

	-- parent so the explosion actually exists in the world
	ea.Parent = workspace
end

function EnemyClass:Destroy()
	self.State = "Dead"
	self:ClearDebugPath()
	if self.Model and self.Model.Parent then
		self.Model:Destroy()
	end
end

-- base attack: checks distance, cooldown, then hits + knockback
function EnemyClass:TryAttack(now: number)
	local t = self.Target
	if not t then
		return
	end

	local c = t.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not h or not root or h.Health <= 0 then
		return
	end

	local d = (root.Position - self.Root.Position).Magnitude
	if d > cfg.Enemy.attackRange then
		return
	end

	if now - self.LastAttack < cfg.Enemy.attackCooldown then
		return
	end

	self.LastAttack = now

	h:TakeDamage(self.Damage)

	local hitSound = Instance.new("Sound")
	hitSound.SoundId = "rbxassetid://8595975458"
	hitSound.Volume = 1
	hitSound.Parent = root
	hitSound:Play()
	DBR:AddItem(hitSound, 2)

	Knockback(root, self.Root.Position, self.KnockbackMult)
end

-- build a path from enemy to target
function EnemyClass:ComputePath(targetPos: Vector3, now: number)
	self.LastPath = now
	self.LastTargetPos = targetPos

	local path = PathS:CreatePath()
	path:ComputeAsync(self.Root.Position, targetPos)

	if path.Status ~= Enum.PathStatus.Success then
		self.Path = nil
		self.Waypoints = nil
		self.WaypointIndex = 0
		self:ClearDebugPath()
		return
	end

	local wps = path:GetWaypoints()
	if #wps == 0 then
		self.Path = nil
		self.Waypoints = nil
		self.WaypointIndex = 0
		self:ClearDebugPath()
		return
	end

	self.Path = path
	self.Waypoints = wps
	self.WaypointIndex = (#wps >= 2) and 2 or 1 -- skip the first wp
	self:ShowPath(path)
end

-- see if we need to refresh the path based on time or how far target moved
function EnemyClass:UpdatePath(now: number, targetPos: Vector3)
	local needNew = false

	if not self.Path or not self.Waypoints or self.WaypointIndex == 0 or self.WaypointIndex > #self.Waypoints then
		needNew = true
	else
		-- save performance by only recalculating the path if enough time has passed, or the target has moved far enoughh.
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
	local wps = self.Waypoints
	if not wps or #wps == 0 then
		self.Hum:MoveTo(targetPos)
		return
	end

	local index = self.WaypointIndex
	if index < 1 then
		index = 1
		self.WaypointIndex = 1
	end

	if index > #wps then
		self.Hum:MoveTo(targetPos)
		return
	end

	local root = self.Root
	local wp = wps[index]

	local wpPosFlat = Vector3.new(wp.Position.X, root.Position.Y, wp.Position.Z)
	local dist = (wpPosFlat - root.Position).Magnitude

	if dist < cfg.Enemy.waypointReachDist then
		index += 1
		self.WaypointIndex = index
		if index > #wps then
			self.Hum:MoveTo(targetPos)
			return
		end
		wp = wps[index]
		wpPosFlat = Vector3.new(wp.Position.X, root.Position.Y, wp.Position.Z)
	end

	if wp.Action == Enum.PathWaypointAction.Jump then
		self.Hum.Jump = true
	end

	self.Hum:MoveTo(wpPosFlat)
end

-- main enemy update per frame
function EnemyClass:Step(_dt: number, now: number)
	if self.State == "Dead" then
		return
	end

	local t = self.Target
	local c = t and t.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local h = c and c:FindFirstChildOfClass("Humanoid")

	-- if current target is gone / dead, try to find another player
	if not t or not c or not root or not h or h.Health <= 0 then
		self.Target = GetNearestPlayer(self)
		t = self.Target
		c = t and t.Character
		root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		h = c and c:FindFirstChildOfClass("Humanoid")
		if not t or not c or not root or not h or h.Health <= 0 then
			self.State = "Idle"
			self.Hum:MoveTo(self.Root.Position)
			return
		end
	end

	if self.State == "Idle" then
		self.State = "Chasing"
	end

	self:UpdatePath(now, root.Position)
	self:FollowPath(root.Position)
	self:TryAttack(now)
end

-- waves

-- returns true if all enemies in this list are dead
local function AllDead(list: { Enemy }): boolean
	for _, e in ipairs(list) do
		if e.State ~= "Dead" then
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
	self.Wave = 0
	self.State = "Waiting"
	self.Time = 0
	self.Enemies = {}
	self.BossInterval = 3
	self.NextBossWave = 3
	return self
end

-- how many enemies to spawn this wave
function WaveClass:GetEnemyCount(): number
	local base = cfg.Wave.baseEnemyCount
	local grow = cfg.Wave.enemyCountGrowth
	return base + grow * self.Wave
end

function WaveClass:ClearEnemies()
	for _, e in ipairs(self.Enemies) do
		e:Destroy()
	end
	table.clear(self.Enemies)
end

-- starts a new wave and spawns enemies
function WaveClass:SpawnWave()
	self.Wave += 1
	if self.Wave > cfg.Wave.maxWave then
		self.Wave = 1
	end

	self.State = "InWave"
	self.Time = 0

	local total = self:GetEnemyCount()
	local isBossWave = (self.Wave == self.NextBossWave)

	SendWaveText(string.format("Wave %d", self.Wave))

	if isBossWave then
		SendInfoText("Boss wave! Survive this round.")
	else
		SendInfoText("Enemies incoming.")
	end

	local remaining = total

	-- drop in a boss on boss waves, then push next boss wave further
	if isBossWave then
		local bossCf = GetSpawnCF()
		local bossEnemy = EnemyClass.new(bossCf, "Boss")
		table.insert(self.Enemies, bossEnemy)
		remaining -= 1

		self.BossInterval += 1
		self.NextBossWave = self.Wave + self.BossInterval
		BroadcastBossInfo()
	end

	local runnerChancePercent = GetRunnerChancePercent(self.Wave)
	local tankChancePercent = 10
	local exploderChancePercent = 12

	-- roll type for each remaining enemy
	for _ = 1, math.max(0, remaining) do
		local kind: EnemyKind = "Normal"
		local roll = math.random(1, 100)

		if roll <= tankChancePercent then
			kind = "Tank"
		elseif roll <= tankChancePercent + runnerChancePercent then
			kind = "Runner"
		elseif roll <= tankChancePercent + runnerChancePercent + exploderChancePercent then
			kind = "Exploder"
		end

		local cf = GetSpawnCF()
		local enemy = EnemyClass.new(cf, kind)
		table.insert(self.Enemies, enemy)
	end
end

-- actual wave loop, waiting > intermission > in wave and loop againn
function WaveClass:Update(dt: number)
	self.Time += dt

	local alive = GetAlivePlayers()
	if #alive < cfg.Misc.minPlayers then
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
		local remain = math.max(0, math.floor(cfg.Wave.intermissionDuration - self.Time))
		SendInfoText(string.format("Next wave in %d second(s)...", remain))
		if self.Time >= cfg.Wave.intermissionDuration then
			self:SpawnWave()
		end
		return
	end

	if self.State == "InWave" then
		local now = os.clock()

		for _, e in ipairs(self.Enemies) do
			e:Step(dt, now)
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
			task.delay(2,function() -- lil delay to make enemy bodies linger for a bit longer
				self:ClearEnemies()
			end)
			SendWaveText("Intermission")
			return
		end
	end
end

-- players

-- collision group setting & announcement when a player dies
local function OnCharAdded(char: Model)
	local h = char:FindFirstChildOfClass("Humanoid")
	if h then
		SetModelCollisionGroup(char, "Players")

		h.Died:Connect(function()
			SendInfoText("A player has fallen...")
		end)
	end
end

local function OnPlayerAdded(plr: Player)
	plr.CharacterAdded:Connect(OnCharAdded)
	BroadcastBossInfo()
end

local function OnPlayerRemoving(_plr: Player)
	if not Waves then
		return
	end

	-- if this was the last player, hard reset waves
	if #P:GetPlayers() <= 1 then
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

P.PlayerAdded:Connect(OnPlayerAdded)
P.PlayerRemoving:Connect(OnPlayerRemoving)

for _, plr in ipairs(P:GetPlayers()) do
	OnPlayerAdded(plr)
end

RunS.Heartbeat:Connect(function(dt: number)
	local w = Waves
	if w then
		w:Update(dt)
	end
end)
