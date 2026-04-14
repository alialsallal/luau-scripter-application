local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local rng = Random.new()

-- grouped settings so i can tweak the whole feel of the weapon here
local CONFIG = {
	MuzzleOffset = Vector3.new(0.65, -0.35, 1.2),
	DefaultGravity = Vector3.new(0, -Workspace.Gravity, 0),
	MaxLifetime = 6,
	DebugLifetime = 0.18,
	PoolSize = 35,
	ResetHeight = -25,
}

-- two ammo types so the showcase has something obvious to switch between
local AMMO_TYPES = {
	{
		Name = "Standard",
		Speed = 260,
		Spread = 1.1,
		Radius = 0.36,
		Color = Color3.fromRGB(80, 190, 255),
		Damage = 34,
		GravityScale = 0.9,
		FireInterval = 0.12,
		Bounces = 1,
		BounceDamping = 0.62,
		RicochetThreshold = 0.35,
		ExplosionRadius = 0,
	},
	{
		Name = "Explosive",
		Speed = 190,
		Spread = 2.2,
		Radius = 0.48,
		Color = Color3.fromRGB(255, 160, 70),
		Damage = 18,
		GravityScale = 1.05,
		FireInterval = 0.35,
		Bounces = 0,
		BounceDamping = 0,
		RicochetThreshold = 0,
		ExplosionRadius = 15,
	},
}

local currentAmmoIndex = 1
local triggerHeld = false
local debugEnabled = true
local lastShotTime = 0
local activeProjectiles = {}
local shotsFired = 0

-- keeping visuals in their own folder makes them easier to ignore in raycasts
local visualsFolder = Instance.new("Folder")
visualsFolder.Name = "ProjectileShowcaseVisuals"
visualsFolder.Parent = Workspace

-- small hud just to show controls and current ammo
local gui = Instance.new("ScreenGui")
gui.Name = "ProjectileShowcaseGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.BackgroundTransparency = 1
titleLabel.Position = UDim2.fromOffset(18, 18)
titleLabel.Size = UDim2.fromOffset(420, 28)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 22
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "Projectile Showcase"
titleLabel.Parent = gui

local infoLabel = Instance.new("TextLabel")
infoLabel.Name = "Info"
infoLabel.BackgroundTransparency = 1
infoLabel.Position = UDim2.fromOffset(18, 48)
infoLabel.Size = UDim2.fromOffset(480, 84)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 15
infoLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
infoLabel.TextWrapped = true
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.TextYAlignment = Enum.TextYAlignment.Top
infoLabel.Parent = gui

local crosshair = Instance.new("Frame")
crosshair.Name = "Crosshair"
crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
crosshair.Position = UDim2.fromScale(0.5, 0.5)
crosshair.Size = UDim2.fromOffset(6, 6)
crosshair.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
crosshair.BorderSizePixel = 0
crosshair.Parent = gui

-- this is mainly so the local player does not instantly hit themselves
local function getCharacter()
	local character = player.Character or player.CharacterAdded:Wait()
	return character
end

-- using the camera for aim makes the shots line up with where the player looks
local function getCamera()
	return Workspace.CurrentCamera
end

-- update the text whenever ammo changes or a shot gets fired
local function updateInfo()
	local ammo = AMMO_TYPES[currentAmmoIndex]
	infoLabel.Text = string.format(
		"[LMB] Fire  [Q] Switch Ammo  [F] Toggle Debug  [R] Clear Projectiles\nAmmo: %s | Shots: %d | Debug: %s",
		ammo.Name,
		shotsFired,
		if debugEnabled then "On" else "Off"
	)
	crosshair.BackgroundColor3 = ammo.Color
end

-- spread is applied relative to the original direction instead of world space
local function applySpread(direction, spreadDegrees)
	local basis = CFrame.lookAt(Vector3.zero, direction)
	local pitch = math.rad(rng:NextNumber(-spreadDegrees, spreadDegrees))
	local yaw = math.rad(rng:NextNumber(-spreadDegrees, spreadDegrees))
	return (basis * CFrame.Angles(pitch, yaw, 0)).LookVector.Unit
end

-- simple object pool so i dont keep creating and deleting visual parts
local PartPool = {}
PartPool.__index = PartPool

function PartPool.new(size)
	local self = setmetatable({}, PartPool)
	self.Available = {}

	-- prebuild a bunch of parts up front
	for _ = 1, size do
		local part = Instance.new("Part")
		part.Name = "ProjectileVisual"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Shape = Enum.PartType.Ball
		part.Material = Enum.Material.Neon
		part.CastShadow = false
		part.Transparency = 1
		part.Size = Vector3.one * 0.4
		part.Parent = visualsFolder
		table.insert(self.Available, part)
	end

	return self
end

function PartPool:Get()
	local part = table.remove(self.Available)

	-- if i run out just make one more instead of failing
	if not part then
		part = Instance.new("Part")
		part.Name = "ProjectileVisual"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Shape = Enum.PartType.Ball
		part.Material = Enum.Material.Neon
		part.CastShadow = false
		part.Parent = visualsFolder
	end

	part.Transparency = 0
	return part
end

function PartPool:Return(part)
	-- reset the visual before it goes back into the pool
	part.Transparency = 1
	part.Size = Vector3.one * 0.4
	part.CFrame = CFrame.new(0, -500, 0)
	part.Color = Color3.new(1, 1, 1)
	table.insert(self.Available, part)
end

local projectilePool = PartPool.new(CONFIG.PoolSize)

-- quick white flash so hits are easier to notice
local function flashPart(part, flashColor)
	local originalColor = Color3.new(
		part:GetAttribute("BaseColorR") or part.Color.R,
		part:GetAttribute("BaseColorG") or part.Color.G,
		part:GetAttribute("BaseColorB") or part.Color.B
	)

	local flashTween = TweenService:Create(part, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = flashColor,
	})

	local resetTween = TweenService:Create(part, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = originalColor,
	})

	flashTween:Play()
	flashTween.Completed:Connect(function()
		if part.Parent then
			resetTween:Play()
		end
	end)
end

-- save the original values once so targets can be restored later
local function cacheTargetState(part, currentHitPoints)
	if part:GetAttribute("MaxHitPoints") == nil then
		part:SetAttribute("MaxHitPoints", currentHitPoints)
	end

	if part:GetAttribute("BaseColorR") == nil then
		part:SetAttribute("BaseColorR", part.Color.R)
		part:SetAttribute("BaseColorG", part.Color.G)
		part:SetAttribute("BaseColorB", part.Color.B)
	end
end

-- any part with a HitPoints attribute counts as a target
local function damageTarget(part, damage)
	local hitPoints = part:GetAttribute("HitPoints")

	-- skip dead or invalid targets
	if not hitPoints or part:GetAttribute("Inactive") then
		return false
	end

	cacheTargetState(part, hitPoints)

	-- subtract health and flash the part
	hitPoints -= damage
	part:SetAttribute("HitPoints", hitPoints)
	flashPart(part, Color3.fromRGB(255, 255, 255))

	-- if it reaches 0 just hide it for a moment and then restore it
	if hitPoints <= 0 then
		local maxHitPoints = part:GetAttribute("MaxHitPoints") or 100
		part:SetAttribute("Inactive", true)
		part:SetAttribute("HitPoints", 0)
		part.Transparency = 0.72
		part.CanCollide = false
		part.Color = Color3.fromRGB(30, 30, 30)
		task.delay(2.5, function()
			if part.Parent then
				part:SetAttribute("Inactive", false)
				part:SetAttribute("HitPoints", maxHitPoints)
				part.Transparency = 0
				part.CanCollide = true
				part.Color = Color3.new(
					part:GetAttribute("BaseColorR"),
					part:GetAttribute("BaseColorG"),
					part:GetAttribute("BaseColorB")
				)
			end
		end)
	end
	return true
end

local Projectile = {}
Projectile.__index = Projectile

-- each projectile keeps its own movement data and its own visual
function Projectile.new(origin, direction, ammoData)
	local self = setmetatable({}, Projectile)
	self.Ammo = ammoData
	self.Position = origin
	self.Velocity = direction * ammoData.Speed
	self.Gravity = CONFIG.DefaultGravity * ammoData.GravityScale
	self.LifeRemaining = CONFIG.MaxLifetime
	self.BouncesLeft = ammoData.Bounces
	self.Visual = projectilePool:Get()
	self.Visual.Color = ammoData.Color
	self.Visual.Size = Vector3.one * ammoData.Radius
	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RaycastParams.IgnoreWater = true
	-- ignore the player and the projectile visuals themselves
	self.RaycastParams.FilterDescendantsInstances = {getCharacter(), visualsFolder}
	self.Alive = true
	self.Spin = rng:NextNumber(-9, 9)
	self.Visual.CFrame = CFrame.lookAt(origin, origin + direction)
	return self
end

-- these markers are just for testing so i can see impacts easier
function Projectile:DrawDebug(position, color, size)
	if not debugEnabled then
		return
	end

	local marker = Instance.new("Part")
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.Material = Enum.Material.Neon
	marker.Shape = Enum.PartType.Ball
	marker.Color = color
	marker.Size = Vector3.one * size
	marker.CFrame = CFrame.new(position)
	marker.Parent = visualsFolder
	Debris:AddItem(marker, CONFIG.DebugLifetime)
end

-- hide the projectile and give the part back to the pool
function Projectile:Destroy()
	if not self.Alive then
		return
	end

	self.Alive = false
	projectilePool:Return(self.Visual)
end

-- explosive ammo checks every target in range and applies splash damage
function Projectile:Explode(position)
	self:DrawDebug(position, Color3.fromRGB(255, 170, 40), self.Ammo.ExplosionRadius * 0.18)

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:GetAttribute("HitPoints") then
			local distance = (descendant.Position - position).Magnitude

			if distance <= self.Ammo.ExplosionRadius then
				local multiplier = 1 - (distance / self.Ammo.ExplosionRadius)
				local damage = math.floor(self.Ammo.Damage + (36 * multiplier))
				damageTarget(descendant, damage)
			end
		end
	end
end

-- this handles what happens after a raycast actually hits something
function Projectile:ResolveHit(result)
	local hitPart = result.Instance
	local hitTarget = hitPart and hitPart:GetAttribute("HitPoints") ~= nil

	-- explosive rounds do direct damage and then splash
	if self.Ammo.ExplosionRadius > 0 then
		if hitTarget then
			damageTarget(hitPart, self.Ammo.Damage)
		end
		self:Explode(result.Position)
		self:DrawDebug(result.Position, Color3.fromRGB(255, 90, 50), 1)
		self:Destroy()
		return
	end

	-- standard direct hit
	if hitTarget then
		damageTarget(hitPart, self.Ammo.Damage)
		self:DrawDebug(result.Position, Color3.fromRGB(120, 255, 120), 0.6)
		self:Destroy()
		return
	end

	local approach = -self.Velocity.Unit:Dot(result.Normal)
	local shouldBounce = self.BouncesLeft > 0 and approach < self.Ammo.RicochetThreshold

	-- shallow angles can bounce instead of stopping right away
	if shouldBounce then
		self.BouncesLeft -= 1
		self.Position = result.Position + (result.Normal * 0.1)
		self.Velocity = (self.Velocity - (2 * self.Velocity:Dot(result.Normal) * result.Normal)) * self.Ammo.BounceDamping
		self:DrawDebug(result.Position, Color3.fromRGB(255, 255, 80), 0.5)
		return
	end

	self:DrawDebug(result.Position, Color3.fromRGB(255, 80, 80), 0.5)
	self:Destroy()
end

-- every frame the projectile moves forward and raycasts through that path
-- this keeps it from skipping through thin parts
function Projectile:Step(dt)
	if not self.Alive then
		return false
	end

	-- remove the projectile if it lives too long or falls too far down
	self.LifeRemaining -= dt

	if self.LifeRemaining <= 0 or self.Position.Y < CONFIG.ResetHeight then
		self:Destroy()
		return false
	end

	local nextVelocity = self.Velocity + (self.Gravity * dt)
	local nextPosition = self.Position + (self.Velocity * dt) + (0.5 * self.Gravity * dt * dt)
	local rayDirection = nextPosition - self.Position
	local result = Workspace:Raycast(self.Position, rayDirection, self.RaycastParams)

	-- if the raycast hits something resolve that instead of just moving
	if result then
		self.Position = result.Position
		self:ResolveHit(result)
	else
		self.Position = nextPosition
		self.Velocity = nextVelocity
	end

	-- rotate the visual so it faces where the projectile is travelling
	if self.Alive then
		local lookDirection = self.Velocity.Magnitude > 0.001 and self.Velocity.Unit or self.Visual.CFrame.LookVector
		local lookPosition = self.Position + lookDirection
		local roll = CFrame.Angles(0, 0, os.clock() * self.Spin)
		self.Visual.CFrame = CFrame.lookAt(self.Position, lookPosition) * roll
	end

	return self.Alive
end

local function getCurrentAmmo()
	return AMMO_TYPES[currentAmmoIndex]
end

-- just loops through the ammo table
local function cycleAmmo()
	currentAmmoIndex += 1

	if currentAmmoIndex > #AMMO_TYPES then
		currentAmmoIndex = 1
	end

	updateInfo()
end

-- offset the spawn point so the shot starts slightly in front of the player
local function getMuzzlePosition()
	local camera = getCamera()
	local cameraCFrame = camera.CFrame
	return cameraCFrame.Position
		+ (cameraCFrame.RightVector * CONFIG.MuzzleOffset.X)
		+ (cameraCFrame.UpVector * CONFIG.MuzzleOffset.Y)
		+ (cameraCFrame.LookVector * CONFIG.MuzzleOffset.Z)
end

-- creates a projectile aimed at the mouse hit position
local function fireProjectile()
	local ammo = getCurrentAmmo()
	local origin = getMuzzlePosition()
	local targetPosition = mouse.Hit and mouse.Hit.Position or (origin + (getCamera().CFrame.LookVector * 300))
	local direction = (targetPosition - origin).Unit
	local adjustedDirection = applySpread(direction, ammo.Spread)
	local projectile = Projectile.new(origin, adjustedDirection, ammo)
	-- keep a simple shot counter for the ui
	shotsFired += 1
	lastShotTime = os.clock()
	table.insert(activeProjectiles, projectile)
	updateInfo()
end

-- useful while testing so old shots can be cleared out instantly
local function resetProjectiles()
	for _, projectile in ipairs(activeProjectiles) do
		projectile:Destroy()
	end

	table.clear(activeProjectiles)
end

-- handles click start and keybinds
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		triggerHeld = true
	elseif input.KeyCode == Enum.KeyCode.Q then
		cycleAmmo()
	elseif input.KeyCode == Enum.KeyCode.F then
		debugEnabled = not debugEnabled
		updateInfo()
	elseif input.KeyCode == Enum.KeyCode.R then
		resetProjectiles()
	end
end)

-- only used so holding mouse1 can stop correctly
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		triggerHeld = false
	end
end)

-- if the player respawns i need to refresh the ignore list on active shots
player.CharacterAdded:Connect(function()
	task.wait(0.2)
	for _, projectile in ipairs(activeProjectiles) do
		if projectile.Alive then
			projectile.RaycastParams.FilterDescendantsInstances = {getCharacter(), visualsFolder}
		end
	end
end)

updateInfo()

-- main update loop for firing and projectile simulation
RunService.RenderStepped:Connect(function(dt)
	local now = os.clock()
	local ammo = getCurrentAmmo()

	-- keep firing while mouse1 is held and enough time has passed
	if triggerHeld and (now - lastShotTime) >= ammo.FireInterval then
		fireProjectile()
	end

	-- update all active projectiles and remove dead ones
	for index = #activeProjectiles, 1, -1 do
		local projectile = activeProjectiles[index]
		local alive = projectile:Step(dt)

		if not alive then
			table.remove(activeProjectiles, index)
		end
	end
end)
