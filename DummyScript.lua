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
local Players = game:GetService("Players") -- service to get all players in the server
local RunService = game:GetService("RunService") -- service used for heartbeat loop / updates
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- shared storage for remote events / models
local TweenService = game:GetService("TweenService") -- used for the little death tween
local Workspace = game:GetService("Workspace") -- main game world

-- Remotes
local attackEvent = ReplicatedStorage:FindFirstChild("AttackDummy") -- remote fired by the tool to tell the server to damage a dummy

-- Config table
local CONFIG = {} -- table to hold all the tweakable options
CONFIG.DUMMY_MODEL_NAME = "TrainingDummy" -- name of the dummy model in replicated storage
CONFIG.SPAWN_FOLDER_NAME = "DummySpawns" -- name of the folder in workspace that holds spawn parts
CONFIG.DUMMY_COUNT = 5 -- how many dummies to spawn total
CONFIG.DUMMY_MAX_HEALTH = 100 -- health each dummy starts with
CONFIG.RESPAWN_TIME = 5 -- how long before a dead dummy respawns
CONFIG.MOVING_DUMMY_CHANCE = 0.4 -- chance that a dummy is orbit or bob instead of static
CONFIG.ORBIT_RADIUS = 2 -- how far orbiting dummies are from their center
CONFIG.ORBIT_SPEED = 1 -- how fast they orbit around
CONFIG.BOB_HEIGHT = 2 -- how high the bobbing goes
CONFIG.BOB_SPEED = 2 -- how fast they bob up and down
CONFIG.KNOCKBACK_FORCE = 70 -- how hard static dummies get pushed

-- runtime tables
local DummyList = {}	-- list of the dummy objects created by the class
local usedSpawns = {}	-- list of the used spawns so that dummy's don't spawn ontop of eachother unless forced too

-- Utility Functions

local function getSpawnPoints() -- gets all the parts in the spawn folder and returns them
	-- the folder in the workspace that contains the spawn locations
	local folder = Workspace:FindFirstChild(CONFIG.SPAWN_FOLDER_NAME) -- try to get the folder by name
	if not folder then
		warn("No spawn folder ' " .. CONFIG.SPAWN_FOLDER_NAME .. " ' found so using origin.") -- warn if the folder isn't there
		return {Workspace:WaitForChild("Terrain")} -- if the folder isn't found, it defaults to the terrain
	end
	local points = {} -- will hold the parts we find
	-- fills the points table by looping through the spawns folder and inserting the part for when we spawn the dummies later
	for _, part in ipairs(folder:GetChildren()) do -- loop all children in the folder
		if part:IsA("BasePart") then -- only care about parts
			table.insert(points, part) -- add it to the list
		end
	end
	return points -- give back the list
end

-- function to make sure that each spawn is used once before reusing to try to avoid making the dummies spawn on top of eachother if other spawns are avaliable
local function getUniqueSpawnCFrame(spawnPoints) -- picks a spawn that hasn't been used yet
	if #spawnPoints == 0 or spawnPoints[1] == Workspace.Terrain then -- if for some reason we have no real spawns
		return CFrame.new(0, 5, 0) -- just put it in the air at origin
	end

	local available = {} -- spawns we can actually use right now
	-- loops through the spawn points and checks if the part is in the usedSpawns table. If so skips it and moves on to the next, if not then it adds it to the avaliable table
	for _, part in ipairs(spawnPoints) do -- check each spawn part
		if not usedSpawns[part] then -- if this one isn't used yet
			table.insert(available, part) -- add to options
		end
	end
	-- if all the spawns are in the usespawns table then it resorts to using the default spawnpoints folder
	if #available == 0 then -- everything was used already
		usedSpawns = {} -- reset the list so we can use them again
		available = spawnPoints -- and now everything is available
	end

	local chosen = available[math.random(1, #available)] -- randomly pick one of the available spawns
	usedSpawns[chosen] = true -- mark it as used
	return chosen.CFrame + Vector3.new(0, 3, 0) -- return the cframe slightly above the part
end

-- functions for applying the knockback on the hit dummy when the gun hits a static dummy
local function applyKnockback(humanoidRootPart, dir) -- pushes the dummy backwards
	if not humanoidRootPart then -- make sure we actually have something to push
		return -- nothing to do if no root
	end
	local bodyVelocity = Instance.new("BodyVelocity") -- create the force
	bodyVelocity.MaxForce = Vector3.new(1e5, 1e5, 1e5) -- let it actually move the dummy
	bodyVelocity.Velocity = dir * CONFIG.KNOCKBACK_FORCE + Vector3.new(0, 30, 0) -- push them in the direction plus a bit up
	bodyVelocity.Parent = humanoidRootPart -- attach it to the root
	game.Debris:AddItem(bodyVelocity, 0.3) -- clean it up after a short time
end

-- the dummy class used for ease of dummy creation and modification
local Dummy = {} -- table to hold the class stuff
Dummy.__index = Dummy -- turns it into a metatable based object

-- the dummy constructor that defines all the dummy's properties
function Dummy.new(model, behavior) -- makes a brand new dummy object from the model
	local self = setmetatable({}, Dummy) -- allows the script to access the instances' functions
	self.Model = model -- store the actual model
	self.Root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart -- get the root so we can move it later
	self.Humanoid = model:FindFirstChildOfClass("Humanoid") -- grab the humanoid to do damage
	self.SpawnCFrame = self.Root and self.Root.CFrame or CFrame.new(0, 5, 0) -- remember where it first spawned
	self.MaxHealth = CONFIG.DUMMY_MAX_HEALTH -- set the max hp from config
	self.Health = self.MaxHealth -- current hp starts max
	self.IsAlive = true -- flag so we don't update dead ones
	self.Behavior = behavior or "STATIC" -- STATIC (default), ORBIT, BOB
	self.OrbitAngle = math.random() * math.pi * 2 -- random start angle for orbiting ones
	self.OrbitCenter = self.SpawnCFrame.Position -- center point for orbit to spin around
	self.LastHit = 0 -- just in case we want cooldowns later
	return self -- return the new dummy object
end

-- when the Dummy dies, respawn it back to it's original spawn cframe and set it's health back to the max
function Dummy:Respawn() -- brings the dummy back to life
	if not self.Model then -- if somehow we don't have a model anymore
		return -- just stop
	end
	self.Health = self.MaxHealth -- reset hp
	self.IsAlive = true -- mark alive again
	if self.Humanoid then -- if we have a humanoid
		self.Humanoid.Health = self.MaxHealth -- sync the real humanoid health
	end
	if self.Root then -- if we have a root part
		self.Root.CFrame = self.SpawnCFrame -- move it back to spawn
		self.Root.AssemblyLinearVelocity = Vector3.zero -- stop any leftover velocity
	end
	self.Model.Parent = Workspace -- actually put it back in the world
end

-- handles the dummy's knockback connection and edits the humanoids health as well. When it's health reaches zero, the die function is ran
function Dummy:TakeDamage(amount, hitter) -- called by the remote when a dummy gets shot
	if not self.IsAlive then -- don't damage dead ones
		return -- stop here
	end
	self.Health = self.Health - amount -- remove health from our own tracker
	if self.Humanoid then -- and from the real humanoid
		self.Humanoid:TakeDamage(amount) -- roblox health
	end
	if hitter and hitter.Character and hitter.Character:FindFirstChild("HumanoidRootPart") and self.Root then -- make sure we can get the direction
		local dir = (self.Root.Position - hitter.Character.HumanoidRootPart.Position).Unit -- direction from player to dummy
		applyKnockback(self.Root, dir) -- actually push it
	end
	if self.Health <= 0 then -- check if we killed it
		self:Die() -- run the death
	end
end

function Dummy:Die() -- handles the death visuals + respawn timer
	-- sets the instance's alive property to false
	self.IsAlive = false
	-- sets the humanoid's (in workspace) health to 0 to trigger it's visual death
	if self.Humanoid then
		self.Humanoid.Health = 0
	end
	if self.Model then -- make sure the model is still around
		if self.Root then -- we can tween the root down a bit
			local tween = TweenService:Create(
				self.Root,
				TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{CFrame = self.Root.CFrame - Vector3.new(0, 2, 0)}
			)
			tween:Play() -- play the little sink effect
		end
		game.Debris:AddItem(self.Model, CONFIG.RESPAWN_TIME) -- remove the dead body after x seconds
	end
	-- after the given respawn time, the dummy is respawned through the function defined earlier
	task.delay(CONFIG.RESPAWN_TIME, function() -- wait some seconds before bringing it back
		if self.SpawnCFrame then -- only respawn if we still have a spawn saved
			local dummyModel = ReplicatedStorage:FindFirstChild(CONFIG.DUMMY_MODEL_NAME) -- grab the original model
			if dummyModel then -- if it exists
				local newModel = dummyModel:Clone() -- make a new copy
				newModel.Parent = Workspace -- put it in the world
				self.Model = newModel -- update the object to point to the new model
				self.Root = newModel.PrimaryPart or newModel:FindFirstChild("HumanoidRootPart") -- update root
				self.Humanoid = newModel:FindFirstChildOfClass("Humanoid") -- update humanoid
				self:Respawn() -- and run respawn logic
			end
		end
	end)
end

-- the function later ran in the run service loop, handles the Dummy's behaviour including the bobbing motion, orbiting motion, and the static dummies facing the player
function Dummy:Update(dt, globalTime) -- updates the dummy every frame
	-- escapes the function if the dummy isn't alive
	if not self.IsAlive then
		return
	end
	if not self.Root then -- if somehow the root got deleted then we can't move it
		return
	end
	-- oribiting motion
	if self.Behavior == "ORBIT" then -- handle the orbiting type
		self.OrbitAngle += CONFIG.ORBIT_SPEED * dt -- move the angle forward
		local offset = CFrame.new(0, 0, -CONFIG.ORBIT_RADIUS) -- how far from center
		local rot = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), self.OrbitAngle) -- rotate around y
		local final = CFrame.new(self.OrbitCenter) * rot * offset -- combine it all
		self.Root.CFrame = final -- apply it to the dummy
		-- bobbing motion
	elseif self.Behavior == "BOB" then -- handle the bobbing type
		local bob = math.sin(globalTime * CONFIG.BOB_SPEED) * CONFIG.BOB_HEIGHT -- calc the height
		self.Root.CFrame = self.SpawnCFrame + Vector3.new(0, bob, 0) -- move the dummy up and down
	else
		-- static: face nearest player by finding the nearest player and changing the CFrame rotation to look at them
		local nearestPlayer, dist = nil, math.huge -- placeholders for the closest player
		for _, plr in ipairs(Players:GetPlayers()) do -- loop through all players
			if plr.Character and plr.Character.PrimaryPart then -- make sure they have a character
				local d = (plr.Character.PrimaryPart.Position - self.Root.Position).Magnitude -- get the distance to them
				if d < dist then -- if closer than the one we had
					dist = d -- update distance
					nearestPlayer = plr -- and store the player
				end
			end
		end
		if nearestPlayer and nearestPlayer.Character and nearestPlayer.Character.PrimaryPart then -- make sure we really have one
			local lookAt = CFrame.lookAt(self.Root.Position, nearestPlayer.Character.PrimaryPart.Position) -- build cframe to look at them
			self.Root.CFrame = lookAt -- apply the new rotation
		end
	end
end

-- Dummy Manager
local DummyManager = {} -- table for managing all dummy instances
DummyManager.SpawnPoints = getSpawnPoints() -- load all spawn points once

-- spawns the dummy's depending on the config
function DummyManager:SpawnAll() -- set up all dummies at the start
	for i = 1, CONFIG.DUMMY_COUNT do -- loop the amount we want
		self:SpawnOne() -- spawn a single dummy
	end
end

-- finds the avaliable spawn locations depending on the return value of the getUniqueSpawnCFrame helper function defined earlier and spawns the dummy there and accounts for the behavior
function DummyManager:SpawnOne() -- spawns one dummy using a free spawn point
	local template = ReplicatedStorage:FindFirstChild(CONFIG.DUMMY_MODEL_NAME) -- get the base model
	if not template then -- if someone forgot to put it in RS
		warn("No dummy model '" .. CONFIG.DUMMY_MODEL_NAME .. "' in ReplicatedStorage!") -- tell studio
		return -- and stop
	end
	local spawnCF = getUniqueSpawnCFrame(self.SpawnPoints) -- find where to put it
	local clone = template:Clone() -- make a fresh copy
	clone.Parent = Workspace -- put it in the world
	if clone.PrimaryPart then -- if the model has a primary part set
		clone:SetPrimaryPartCFrame(spawnCF) -- move the whole model
	elseif clone:FindFirstChild("HumanoidRootPart") then -- fallback incase no primary part
		clone:FindFirstChild("HumanoidRootPart").CFrame = spawnCF -- just set root cframe
	end

	local behavior = "STATIC" -- default to static
	if math.random() < CONFIG.MOVING_DUMMY_CHANCE then -- if we roll moving
		behavior = (math.random() < 0.5) and "ORBIT" or "BOB" -- 50/50 split between those two
	end

	local d = Dummy.new(clone, behavior) -- create the dummy object
	table.insert(DummyList, d) -- store it for updates
end

-- Attack Handler
attackEvent.OnServerEvent:Connect(function(player, payload) -- when the client says "I hit this dummy"
	if type(payload) ~= "table" then -- make sure we actually got a table
		return -- if not, bail
	end
	local dummyModel = payload.Dummy -- the instance of the dummy we hit
	local damage = tonumber(payload.Damage) or 10 -- how much to damage it by
	if typeof(dummyModel) ~= "Instance" then -- make sure the dummy field is an instance
		return -- if not, don't error
	end
	for _, dummy in ipairs(DummyList) do -- look through all the dummy objects we have
		if dummy.Model == dummyModel then -- if the model matches the one the player sent
			dummy:TakeDamage(damage, player) -- damage that exact dummy
			break -- no need to keep looping
		end
	end
end)

-- main runtime loop
DummyManager:SpawnAll() -- actually spawn all the dummies once at start

local globalTime = 0 -- keep track of time for dummy calculations
RunService.Heartbeat:Connect(function(dt) -- run every frame on the server
	globalTime += dt -- update time
	for _, dummy in ipairs(DummyList) do -- update every dummy we have
		dummy:Update(dt, globalTime) -- run the update function
	end
end)

-- in world credit
do -- using a do block so it doesn't leak variables
	-- create the part
	local creditPart = Instance.new("Part") -- part to hold the billboard
	creditPart.Name = "ScriptCredits" -- name it so we know what it is
	creditPart.Anchored = true -- don't let it fall
	creditPart.CanCollide = false -- don't let it get in the way
	creditPart.Size = Vector3.new(4, 1, 4) -- kind of a plate
	creditPart.CFrame = CFrame.new(0, 5, 0) -- float it above the ground
	creditPart.Parent = Workspace -- put it in the world

	-- create the billboard ui
	local billboard = Instance.new("BillboardGui") -- gui that follows the part
	billboard.Size = UDim2.new(4, 0, 1, 0) -- make it big enough to read
	billboard.AlwaysOnTop = true -- make sure we can see it
	billboard.Parent = creditPart -- attach it to the part

	-- add the label in the ui and update the text
	local label = Instance.new("TextLabel") -- actual text
	label.Size = UDim2.new(1, 0, 1, 0) -- fill the billboard
	label.BackgroundTransparency = 1 -- no background
	label.TextColor3 = Color3.new(1, 1, 1) -- white text
	label.TextStrokeTransparency = 0.5 -- little outline
	label.Font = Enum.Font.RobotoMono -- font I like
	label.TextScaled = true -- auto scale
	label.Text = "Arena Trainer Script by @sreescripting" -- text to show
	label.Parent = billboard -- attach it
end
