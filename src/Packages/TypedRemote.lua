--!strict
--[=[
	@class TypedRemote
	Creates typed RemoteEvents and RemoteFunctions with intellisense-friendly wrappers.
]=]

type Signal<T...> = {
	Connect         : (self: Signal<T...>, fn: (T...) -> ()) -> RBXScriptConnection,
	ConnectParallel : (self: Signal<T...>, fn: (T...) -> ()) -> RBXScriptConnection,
	Once            : (self: Signal<T...>, fn: (T...) -> ()) -> RBXScriptConnection,
	Wait            : (self: Signal<T...>) -> T...,
}

type PlayerSignal<T...> = {
	Connect         : (self: PlayerSignal<T...>, fn: (player: Player, T...) -> ()) -> RBXScriptConnection,
	ConnectParallel : (self: PlayerSignal<T...>, fn: (player: Player, T...) -> ()) -> RBXScriptConnection,
	Once            : (self: PlayerSignal<T...>, fn: (player: Player, T...) -> ()) -> RBXScriptConnection,
	Wait            : (self: PlayerSignal<T...>) -> (Player, T...),
}

export type Event<ServerReceive..., ClientReceive...> = Instance & {
	OnClientEvent  : Signal<ClientReceive...>,
	OnServerEvent  : PlayerSignal<ServerReceive...>,
	FireClient     : (self: Event<ServerReceive..., ClientReceive...>, player: Player, ClientReceive...) -> (),
	FireAllClients : (self: Event<ServerReceive..., ClientReceive...>, ClientReceive...) -> (),
	FireServer     : (self: Event<ServerReceive..., ClientReceive...>, ServerReceive...) -> (),
}

export type Function<T..., R...> = Instance & {
	InvokeServer   : (self: Function<T..., R...>, T...) -> R...,
	OnServerInvoke : (player: Player, T...) -> R...,
}

local IS_SERVER = game:GetService("RunService"):IsServer()

local TypedRemote = {}

function TypedRemote.parent(parent: Instance)
	return function(name: string) return TypedRemote.func(name, parent) end,
	       function(name: string) return TypedRemote.event(name, parent) end,
	       function(name: string) return TypedRemote.unreliable(name, parent) end
end

function TypedRemote.func(name: string, parent: Instance?): RemoteFunction
	if IS_SERVER then
		local rf = Instance.new("RemoteFunction")
		rf.Name   = name
		rf.Parent = if parent then parent else script
		return rf
	else
		local rf = (if parent then parent else script):WaitForChild(name, 30)
		assert(rf and rf:IsA("RemoteFunction"), "Expected RemoteFunction '" .. name .. "'")
		return rf :: RemoteFunction
	end
end

function TypedRemote.event(name: string, parent: Instance?): RemoteEvent
	if IS_SERVER then
		local re = Instance.new("RemoteEvent")
		re.Name   = name
		re.Parent = if parent then parent else script
		return re
	else
		local re = (if parent then parent else script):WaitForChild(name, 30)
		assert(re and re:IsA("RemoteEvent"), "Expected RemoteEvent '" .. name .. "'")
		return re :: RemoteEvent
	end
end

function TypedRemote.unreliable(name: string, parent: Instance?): UnreliableRemoteEvent
	if IS_SERVER then
		local re = Instance.new("UnreliableRemoteEvent")
		re.Name   = name
		re.Parent = if parent then parent else script
		return re
	else
		local re = (if parent then parent else script):WaitForChild(name, 30)
		assert(re and re:IsA("UnreliableRemoteEvent"), "Expected UnreliableRemoteEvent '" .. name .. "'")
		return re :: UnreliableRemoteEvent
	end
end

table.freeze(TypedRemote)
return TypedRemote
