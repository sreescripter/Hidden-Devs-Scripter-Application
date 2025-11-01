-- @sreescripting
--[[
    Features:
        - uses the dummy model in replicated storage as well as the spawn locations folder to spawn a dummy on each spawn location
        - When the dummy's are spawned, they either have a bobbing, orbiting or static movement type
        - bobbing and orbiting dummy's don't display knockback while static ones do; static ones also track the player while the others don't
        - Script itself includes a dummy class and a dummy manager:
        	- dummy class: a metatable based object that I created for easier definition and modification of individual dummy behavior
        	- dummy manager: the controller that I created for spawning and updating the dummy instances created off of the class
        - A config table that you can feel free to mess around with (make sure that if you change the model name or folder name to update the corresponding objects in the workspace)
        - a part that displays the credits (you can ignore)
    Note:
        - I intentionally wrote all this in one script to fulfill the criteria although it probably would be cleaner if made in multiple.
        - The gun model was not made by me and is off the toolbox
--]]

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- Remotes
local attackEvent = ReplicatedStorage:FindFirstChild("AttackDummy")

-- Config table
local CONFIG = {}
CONFIG.DUMMY_MODEL_NAME = "TrainingDummy"
CONFIG.SPAWN_FOLDER_NAME = "DummySpawns"
CONFIG.DUMMY_COUNT = 5
CONFIG.DUMMY_MAX_HEALTH = 100
CONFIG.RESPAWN_TIME = 5
CONFIG.MOVING_DUMMY_CHANCE = 0.4
CONFIG.ORBIT_RADIUS = 2
CONFIG.ORBIT_SPEED = 1
CONFIG.BOB_HEIGHT = 2
CONFIG.BOB_SPEED = 2
CONFIG.KNOCKBACK_FORCE = 70

-- runtime tables
local DummyList = {}	-- list of the dummy objects created by the class
local usedSpawns = {}	-- list of the used spawns so that dummy's don't spawn ontop of eachother unless forced too

-- Utility Functions

local function getSpawnPoints()
	-- the folder in the workspace that contains the spawn locations
	local folder = Workspace:FindFirstChild(CONFIG.SPAWN_FOLDER_NAME)
	if not folder then
		warn("No spawn folder ' " .. CONFIG.SPAWN_FOLDER_NAME .. " ' found so using origin.")
		return {Workspace:WaitForChild("Terrain")} -- if the folder isn't found, it defaults to the terrain
	end
	local points = {}
	-- fills the points table by looping through the spawns folder and inserting the part for when we spawn the dummies later
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			table.insert(points, part)
		end
	end
	return points
end

-- function to make sure that each spawn is used once before reusing to try to avoid making the dummies spawn on top of eachother if other spawns are avaliable
local function getUniqueSpawnCFrame(spawnPoints)
	if #spawnPoints == 0 or spawnPoints[1] == Workspace.Terrain then
		return CFrame.new(0, 5, 0)
	end
	
	local available = {}
	-- loops through the spawn points and checks if the part is in the usedSpawns table. If so skips it and moves on to the next, if not then it adds it to the avaliable table
	for _, part in ipairs(spawnPoints) do
		if not usedSpawns[part] then
			table.insert(available, part)
		end
	end
	-- if all the spawns are in the usespawns table then it resorts to using the default spawnpoints folder
	if #available == 0 then
		usedSpawns = {}
		available = spawnPoints
	end

	local chosen = available[math.random(1, #available)]
	usedSpawns[chosen] = true
	return chosen.CFrame + Vector3.new(0, 3, 0)
end

-- functions for applying the knockback on the hit dummy when the gun hits a static dummy
local function applyKnockback(humanoidRootPart, dir)
	if not humanoidRootPart then
		return
	end
	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
	bodyVelocity.Velocity = dir * CONFIG.KNOCKBACK_FORCE + Vector3.new(0, 30, 0)
	bodyVelocity.Parent = humanoidRootPart
	game.Debris:AddItem(bodyVelocity, 0.3)
end

-- the dummy class used for ease of dummy creation and modification
local Dummy = {}
Dummy.__index = Dummy -- turns it into a metatable based object

-- the dummy constructor that defines all the dummy's properties
function Dummy.new(model, behavior)
	local self = setmetatable({}, Dummy) -- allows the script to access the instances' functions
	self.Model = model
	self.Root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	self.Humanoid = model:FindFirstChildOfClass("Humanoid")
	self.SpawnCFrame = self.Root and self.Root.CFrame or CFrame.new(0, 5, 0)
	self.MaxHealth = CONFIG.DUMMY_MAX_HEALTH
	self.Health = self.MaxHealth
	self.IsAlive = true
	self.Behavior = behavior or "STATIC" -- STATIC (default), ORBIT, BOB
	self.OrbitAngle = math.random() * math.pi * 2
	self.OrbitCenter = self.SpawnCFrame.Position
	self.LastHit = 0
	return self
end

-- when the Dummy dies, respawn it back to it's original spawn cframe and set it's health back to the max
function Dummy:Respawn()
	if not self.Model then
		return
	end
	self.Health = self.MaxHealth
	self.IsAlive = true
	if self.Humanoid then
		self.Humanoid.Health = self.MaxHealth
	end
	if self.Root then
		self.Root.CFrame = self.SpawnCFrame
		self.Root.AssemblyLinearVelocity = Vector3.zero
	end
	self.Model.Parent = Workspace
end

-- handles the dummy's knockback connection and edits the humanoids health as well. When it's health reaches zero, the die function is ran
function Dummy:TakeDamage(amount, hitter)
	if not self.IsAlive then
		return
	end
	self.Health = self.Health - amount
	if self.Humanoid then
		self.Humanoid:TakeDamage(amount)
	end
	if hitter and hitter.Character and hitter.Character:FindFirstChild("HumanoidRootPart") and self.Root then
		local dir = (self.Root.Position - hitter.Character.HumanoidRootPart.Position).Unit
		applyKnockback(self.Root, dir)
	end
	if self.Health <= 0 then
		self:Die()
	end
end

function Dummy:Die()
	-- sets the instance's alive property to false
	self.IsAlive = false
	-- sets the humanoid's (in workspace) health to 0 to trigger it's visual death
	if self.Humanoid then
		self.Humanoid.Health = 0
	end
	if self.Model then
		if self.Root then
			local tween = TweenService:Create(
				self.Root,
				TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{CFrame = self.Root.CFrame - Vector3.new(0, 2, 0)}
			)
			tween:Play()
		end
		game.Debris:AddItem(self.Model, CONFIG.RESPAWN_TIME)
	end
	-- after the given respawn time, the dummy is respawned through the function defined earlier
	task.delay(CONFIG.RESPAWN_TIME, function()
		if self.SpawnCFrame then
			local dummyModel = ReplicatedStorage:FindFirstChild(CONFIG.DUMMY_MODEL_NAME)
			if dummyModel then
				local newModel = dummyModel:Clone()
				newModel.Parent = Workspace
				self.Model = newModel
				self.Root = newModel.PrimaryPart or newModel:FindFirstChild("HumanoidRootPart")
				self.Humanoid = newModel:FindFirstChildOfClass("Humanoid")
				self:Respawn()
			end
		end
	end)
end

-- the function later ran in the run service loop, handles the Dummy's behaviour including the bobbing motion, orbiting motion, and the static dummies facing the player
function Dummy:Update(dt, globalTime)
	-- escapes the function if the dummy isn't alive
	if not self.IsAlive then
		return
	end
	if not self.Root then
		return
	end
	-- oribiting motion
	if self.Behavior == "ORBIT" then
		self.OrbitAngle += CONFIG.ORBIT_SPEED * dt
		local offset = CFrame.new(0, 0, -CONFIG.ORBIT_RADIUS)
		local rot = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), self.OrbitAngle)
		local final = CFrame.new(self.OrbitCenter) * rot * offset
		self.Root.CFrame = final
	-- bobbing motion
	elseif self.Behavior == "BOB" then
		local bob = math.sin(globalTime * CONFIG.BOB_SPEED) * CONFIG.BOB_HEIGHT
		self.Root.CFrame = self.SpawnCFrame + Vector3.new(0, bob, 0)
	else
		-- static: face nearest player by finding the nearest player and changing the CFrame rotation to look at them
		local nearestPlayer, dist = nil, math.huge
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character and plr.Character.PrimaryPart then
				local d = (plr.Character.PrimaryPart.Position - self.Root.Position).Magnitude
				if d < dist then
					dist = d
					nearestPlayer = plr
				end
			end
		end
		if nearestPlayer and nearestPlayer.Character and nearestPlayer.Character.PrimaryPart then
			local lookAt = CFrame.lookAt(self.Root.Position, nearestPlayer.Character.PrimaryPart.Position)
			self.Root.CFrame = lookAt
		end
	end
end

-- Dummy Manager
local DummyManager = {}
DummyManager.SpawnPoints = getSpawnPoints()

-- spawns the dummy's depending on the config
function DummyManager:SpawnAll()
	for i = 1, CONFIG.DUMMY_COUNT do
		self:SpawnOne()
	end
end

-- finds the avaliable spawn locations depending on the return value of the getUniqueSpawnCFrame helper function defined earlier and spawns the dummy there and accounts for the behavior
function DummyManager:SpawnOne()
	local template = ReplicatedStorage:FindFirstChild(CONFIG.DUMMY_MODEL_NAME)
	if not template then
		warn("No dummy model '" .. CONFIG.DUMMY_MODEL_NAME .. "' in ReplicatedStorage!")
		return
	end
	local spawnCF = getUniqueSpawnCFrame(self.SpawnPoints)
	local clone = template:Clone()
	clone.Parent = Workspace
	if clone.PrimaryPart then
		clone:SetPrimaryPartCFrame(spawnCF)
	elseif clone:FindFirstChild("HumanoidRootPart") then
		clone:FindFirstChild("HumanoidRootPart").CFrame = spawnCF
	end

	local behavior = "STATIC"
	if math.random() < CONFIG.MOVING_DUMMY_CHANCE then
		behavior = (math.random() < 0.5) and "ORBIT" or "BOB"
	end

	local d = Dummy.new(clone, behavior)
	table.insert(DummyList, d)
end

-- Attack Handler
attackEvent.OnServerEvent:Connect(function(player, payload)
	if type(payload) ~= "table" then
		return
	end
	local dummyModel = payload.Dummy
	local damage = tonumber(payload.Damage) or 10
	if typeof(dummyModel) ~= "Instance" then
		return
	end
	for _, dummy in ipairs(DummyList) do
		if dummy.Model == dummyModel then
			dummy:TakeDamage(damage, player)
			break
		end
	end
end)

-- main runtime loop
DummyManager:SpawnAll()

local globalTime = 0 -- keep track of time for dummy calculations
RunService.Heartbeat:Connect(function(dt)
	globalTime += dt -- update time
	for _, dummy in ipairs(DummyList) do
		dummy:Update(dt, globalTime) -- run the update function
	end
end)

-- in world credit
do
	-- create the part
	local creditPart = Instance.new("Part")
	creditPart.Name = "ScriptCredits"
	creditPart.Anchored = true
	creditPart.CanCollide = false
	creditPart.Size = Vector3.new(4, 1, 4)
	creditPart.CFrame = CFrame.new(0, 5, 0)
	creditPart.Parent = Workspace
	
	-- create the billboard ui
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(4, 0, 1, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = creditPart

	-- add the label in the ui and update the text
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.Font = Enum.Font.RobotoMono
	label.TextScaled = true
	label.Text = "Arena Trainer Script by @sreescripting"
	label.Parent = billboard
end
