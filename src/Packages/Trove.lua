-- Trove
-- Stephen Leitnick
-- October 16, 2021
local FN_MARKER     = newproxy()
local THREAD_MARKER = newproxy()
local GENERIC_OBJECT_CLEANUP_METHODS = { "Destroy", "Disconnect", "destroy", "disconnect" }

local RunService = game:GetService("RunService")

local function GetObjectCleanupFunction(object, cleanupMethod)
	local t = typeof(object)
	if t == "function" then return FN_MARKER end
	if t == "thread"   then return THREAD_MARKER end
	if cleanupMethod   then return cleanupMethod end
	if t == "Instance" then return "Destroy" end
	if t == "RBXScriptConnection" then return "Disconnect" end
	if t == "table" then
		for _, m in GENERIC_OBJECT_CLEANUP_METHODS do
			if typeof(object[m]) == "function" then return m end
		end
	end
	error("Failed to get cleanup function for object " .. t .. ": " .. tostring(object), 3)
end

local function AssertPromiseLike(object)
	if typeof(object) ~= "table"
		or typeof(object.getStatus) ~= "function"
		or typeof(object.finally)   ~= "function"
		or typeof(object.cancel)    ~= "function"
	then error("Did not receive a Promise as an argument", 3) end
end

local function AssertFutureLike(object)
	if typeof(object) ~= "table"
		or typeof(object.Await)  ~= "function"
		or typeof(object.After)  ~= "function"
		or typeof(object.Cancel) ~= "function"
	then error("Did not receive a Future as an argument", 3) end
end

--[=[
	@class Trove
	Tracks objects (Instances, connections, threads, tables) and cleans them
	up together when the trove is destroyed.
]=]
local Trove = {}
Trove.__index = Trove

type self = {
	_objects  : { [any]: any },
	_cleaning : boolean,
}

export type TroveType = typeof(setmetatable({} :: self, Trove))

function Trove.new(): TroveType
	local self = setmetatable({}, Trove)
	self._objects  = {}
	self._cleaning = false
	return self
end

function Trove:Extend()
	if self._cleaning then error("Cannot call trove:Extend() while cleaning", 2) end
	return self:Construct(Trove)
end

function Trove:Clone(instance: Instance): Instance
	if self._cleaning then error("Cannot call trove:Clone() while cleaning", 2) end
	return self:Add(instance:Clone())
end

function Trove:Construct(class, ...)
	if self._cleaning then error("Cannot call trove:Construct() while cleaning", 2) end
	local object = nil
	local t = typeof(class)
	if t == "table"    then object = class.new(...) end
	if t == "function" then object = class(...) end
	return self:Add(object)
end

function Trove:Connect(signal, fn)
	if self._cleaning then error("Cannot call trove:Connect() while cleaning", 2) end
	return self:Add(signal:Connect(fn))
end

function Trove:Once(signal, fn)
	if self._cleaning then error("Cannot call trove:Once() while cleaning", 2) end
	local connection
	connection = signal:Connect(function(...)
		fn(...)
		connection:Disconnect()
		self:_findAndRemoveFromObjects(connection, false)
	end)
	return self:Add(connection)
end

function Trove:BindToRenderStep(name: string, priority: number, fn: (dt: number) -> ())
	if self._cleaning then error("Cannot call trove:BindToRenderStep() while cleaning", 2) end
	RunService:BindToRenderStep(name, priority, fn)
	self:Add(function() RunService:UnbindFromRenderStep(name) end)
end

function Trove:AddPromise(promise)
	if self._cleaning then error("Cannot call trove:AddPromise() while cleaning", 2) end
	AssertPromiseLike(promise)
	if promise:getStatus() == "Started" then
		promise:finally(function()
			if self._cleaning then return end
			self:_findAndRemoveFromObjects(promise, false)
		end)
		self:Add(promise, "cancel")
	end
	return promise
end

function Trove:AddFuture(future)
	if self._cleaning then error("Cannot call trove:AddFuture() while cleaning", 2) end
	AssertFutureLike(future)
	if future:IsPending() then
		future:After(function()
			if self._cleaning then return end
			self:_findAndRemoveFromObjects(future, false)
		end)
		self:Add(future, "Cancel")
	end
	return future
end

function Trove:Add(object: any, cleanupMethod: string?): any
	if self._cleaning then error("Cannot call trove:Add() while cleaning", 2) end
	local cleanup = GetObjectCleanupFunction(object, cleanupMethod)
	table.insert(self._objects, { object, cleanup })
	return object
end

function Trove:Remove(object: any): boolean
	if self._cleaning then error("Cannot call trove:Remove() while cleaning", 2) end
	return self:_findAndRemoveFromObjects(object, true)
end

function Trove:Clean()
	if self._cleaning then return end
	self._cleaning = true
	for _, obj in self._objects do
		self:_cleanupObject(obj[1], obj[2])
	end
	table.clear(self._objects)
	self._cleaning = false
end

function Trove:_findAndRemoveFromObjects(object: any, cleanup: boolean): boolean
	local objects = self._objects
	for i, obj in ipairs(objects) do
		if obj[1] == object then
			local n = #objects
			objects[i] = objects[n]
			objects[n] = nil
			if cleanup then self:_cleanupObject(obj[1], obj[2]) end
			return true
		end
	end
	return false
end

function Trove:_cleanupObject(object, cleanupMethod)
	if cleanupMethod == FN_MARKER then
		object()
	elseif cleanupMethod == THREAD_MARKER then
		pcall(task.cancel, object)
	else
		object[cleanupMethod](object)
	end
end

function Trove:AttachToInstance(instance: Instance)
	if self._cleaning then error("Cannot call trove:AttachToInstance() while cleaning", 2) end
	if not instance:IsDescendantOf(game) then error("Instance is not a descendant of the game hierarchy", 2) end
	return self:Connect(instance.Destroying, function() self:Destroy() end)
end

function Trove:IsCleaning(): boolean
	return self._cleaning
end

function Trove:Destroy()
	self:Clean()
end

return Trove
