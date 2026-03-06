--!strict
--@author: Wags
--@date: 2/6/26
--[=[
	@class AnimationService
	@server
	@client

	Server-client animation management service. Provides `WrappedAnimation` objects
	for loading, playing, pausing, and stopping animations on any rig.

	Supports animation IDs (`number`), asset strings (`string`), or raw `Animation`
	instances as input. Parameters like priority, speed, and looping are configurable
	via `AnimationParams`. On the server, playback is distributed to clients via a
	pool of rotating `RemoteEvent`s. On the client, tracks are loaded and played
	directly on the `Animator`.

	Resource cleanup is handled automatically through Trove. All playback state
	transitions fire a `PlaybackStateChanged` signal for external listeners.

	:::caution
	`Init()` must be called exactly once before any animations are created or played.
	:::

	### Quick Example
	```lua
	-- Server
	local anim = AnimationService:CreateFromRig(character, 123456789)
	anim:Play({ FadeTime = 0.2 })

	-- Listen to state changes
	anim.Signals.PlaybackStateChanged:Connect(function(old, new)
		print("State changed:", old, "->", new)
	end)
	```
]=]

-- // Services

local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- // Requires

local Packages  = script.Parent.Packages
local Signal    = require(Packages.Signal)
local Trove     = require(Packages.Trove)
local Logger    = require(Packages.Logger)
local TableUtil = require(Packages.TableUtil)
local TypedRemote = require(Packages.TypedRemote)

-- // Types

--[=[
	@type ValidAnimation number | string | Animation
	@within AnimationService

	Accepted animation input formats:
	- `number`    — Roblox asset ID (e.g. `123456789`)
	- `string`    — Full asset URL (e.g. `"rbxassetid://123456789"`)
	- `Animation` — A pre-existing `Animation` instance
]=]
type ValidAnimation = number | string | Animation

--[=[
	@interface AnimationParams
	@within AnimationService
	.AnimationPriority Enum.AnimationPriority? -- Playback priority. Defaults to `Action`.
	.AnimationSpeed    number?                 -- Playback speed multiplier. Defaults to `1`.
	.Looped            boolean?                -- Whether the animation loops. Defaults to `false`.
	.AutoPlay          boolean?                -- Automatically play on creation. Defaults to `false`.
	.AutoPlayOptions   PlayOptions?            -- PlayOptions to use when AutoPlay is `true`.

	Configuration passed to `Create` or `CreateFromRig` to control animation behaviour.
	Any omitted fields fall back to their defaults.
]=]
export type AnimationParams = {
	AnimationPriority : Enum.AnimationPriority?,
	AnimationSpeed    : number?,
	Looped            : boolean?,
	AutoPlay          : boolean?,
	AutoPlayOptions   : PlayOptions?,
}

--[=[
	@interface PlayOptions
	@within AnimationService
	.FadeTime number?    -- Blend-in duration in seconds. Defaults to `0.1`.
	.Weight   number?    -- Blend weight. Defaults to `1`.
	.Speed    number?    -- Override playback speed for this play call only.
	.Clients  {Player}? -- Restrict playback to specific clients. `nil` = all clients.

	Options passed to `Play()` to control how the animation starts.
	All fields are optional and fall back to defaults when omitted.
]=]
export type PlayOptions = {
	FadeTime : number?,
	Weight   : number?,
	Speed    : number?,
	Clients  : { Player }?,
}

type self = {
	_playbackState  : Enum.PlaybackState,
	_uniqueId       : string,
	_firedToClients : boolean,
	_targetPlayers  : { Player }?,
	_trove          : Trove.TroveType,
	_params         : AnimationParams,
	_animationId    : string | number,
	_animator       : Animator,
	_rig            : Instance,
	_track          : AnimationTrack?,

	Signals: {
		Played               : Signal.SignalType<() -> (), ()>,
		Paused               : Signal.SignalType<() -> (), ()>,
		Ended                : Signal.SignalType<() -> (), ()>,
		PlaybackStateChanged : Signal.SignalType<
			(Enum.PlaybackState, Enum.PlaybackState) -> (),
			(Enum.PlaybackState, Enum.PlaybackState)
		>,
	},
}

export type WrappedAnimation = typeof(setmetatable({} :: self, {}))
export type AnimationService = typeof({} :: Module)

-- // Constants

local REMOTE_COUNT = 3

local DEFAULT_ANIMATION_PARAMS: AnimationParams = {
	AnimationPriority = Enum.AnimationPriority.Action,
	AnimationSpeed    = 1,
	Looped            = false,
	AutoPlay          = false,
}

local DEFAULT_PLAY_OPTIONS: PlayOptions = {
	FadeTime = 0.1,
	Weight   = 1,
	Clients  = nil,
}

-- // Module Setup

local Module = {}
local MT     = { __index = {} }
type Module  = typeof(Module)

local Log = Logger.new(script.Name)

-- // Remote Events

local playAnimationEvents: { TypedRemote.Event<any, any> } = {}
local currentRemoteIndex = 1

for i = 1, REMOTE_COUNT do
	local event = TypedRemote.event(`_playAnimation{i}`, script)
	table.insert(playAnimationEvents, event)
end

-- // Cache

local animationCache: { [string]: WrappedAnimation } = {}

-- // Private Helpers

--[=[
	@private
	Wraps a number within [min, max], rolling over at either boundary.

	@param x   number  -- The value to loop.
	@param max number  -- The upper bound (inclusive).
	@param min number? -- The lower bound (inclusive). Defaults to `1`.
	@return number -- The looped value clamped within [min, max].
]=]
local function loopNumber(x: number, max: number, min: number?): number
	min = min or 1
	return if x > max then min :: number elseif x < (min :: number) then max else x
end

--[=[
	@private
	@server

	Returns the next `RemoteEvent` from the round-robin pool and advances the index.
	Spreading events across multiple remotes reduces per-event bandwidth pressure.

	@error "server-only" -- Thrown if called from the client.
	@return RemoteEvent -- The next event in the rotation.
]=]
local function getNextRemoteEvent(): RemoteEvent
	Log:assert(RunService:IsServer(), "getNextRemoteEvent() is server-only!")
	local event = playAnimationEvents[currentRemoteIndex]
	currentRemoteIndex = loopNumber(currentRemoteIndex + 1, REMOTE_COUNT)
	return event
end

--[=[
	@private
	Finds the existing `Animator` on a rig's `Humanoid` or `AnimationController`.
	Does **not** create anything if none is found.

	@param rig Instance -- The rig model to search.
	@error "rig does not exist" -- Thrown if `rig` is nil.
	@return Animator? -- The found Animator, or `nil` if none exists.
]=]
local function getRigAnimator(rig: Instance): Animator?
	Log:assert(rig, "rig does not exist")
	local controller = rig:FindFirstChildWhichIsA("Humanoid")
		or rig:FindFirstChildWhichIsA("AnimationController")
	return controller and controller:FindFirstChildWhichIsA("Animator") :: Animator or nil
end

--[=[
	@private
	Finds or creates an `Animator` on the rig. If neither a `Humanoid` nor an
	`AnimationController` exists, an `AnimationController` is created first,
	then an `Animator` is added beneath it.

	@param rig Instance -- The rig model to create the Animator on.
	@error "rig does not exist" -- Thrown if `rig` is nil.
	@return Animator -- The existing or newly created Animator.
]=]
local function createRigAnimator(rig: Instance): Animator
	Log:assert(rig, "rig does not exist")

	local controller = rig:FindFirstChildWhichIsA("Humanoid")
		or rig:FindFirstChildWhichIsA("AnimationController")

	if not controller then
		controller = Instance.new("AnimationController")
		controller.Parent = rig
	end

	local animator = controller:FindFirstChildWhichIsA("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end

	return animator :: Animator
end

--[=[
	@private
	Walks up the `Animator`'s parent chain to find the owning rig `Instance`.
	Supports both `Humanoid`-based characters and `AnimationController`-based models.

	@param animator Animator -- The Animator whose rig should be resolved.
	@error "Invalid Animator parent" -- Thrown if the parent is neither a Humanoid nor an AnimationController.
	@return Instance -- The rig that owns the Animator.
]=]
local function resolveRigFromAnimator(animator: Animator): Instance
	local parent = animator.Parent :: Instance
	if parent:IsA("Humanoid") or parent:IsA("AnimationController") then
		return parent.Parent :: Instance
	end
	error(("[AnimationService] Invalid Animator parent: %s"):format(parent.ClassName), 2)
end

--[=[
	@private
	Converts a `ValidAnimation` into an `Animation` instance and loads it onto
	the given `Animator`, returning the resulting `AnimationTrack`.

	Input handling:
	- `number`    → wrapped as `"rbxassetid://<id>"`
	- `string`    → used as-is for `AnimationId`
	- `Animation` → passed directly to `LoadAnimation`

	@param animator  Animator       -- The Animator to load the track onto.
	@param animation ValidAnimation -- The animation identifier or instance to load.
	@error "animator is invalid" -- Thrown if `animator` is nil or not an Instance.
	@error "animation is nil"    -- Thrown if `animation` is nil.
	@return AnimationTrack -- The loaded (but not yet playing) AnimationTrack.
]=]
local function loadTrack(animator: Animator, animation: ValidAnimation): AnimationTrack
	Log:assert(animator and typeof(animator) == "Instance", "animator is invalid")
	Log:assert(animation, "animation is nil")

	local instance: Animation
	if typeof(animation) == "number" then
		instance = Instance.new("Animation")
		instance.AnimationId = "rbxassetid://" .. animation
	elseif typeof(animation) == "string" then
		instance = Instance.new("Animation")
		instance.AnimationId = animation
	else
		instance = animation :: Animation
	end

	return animator:LoadAnimation(instance)
end

--[=[
	@private
	Yields the calling coroutine until `track.Length > 0`, meaning the animation
	asset has finished loading from Roblox's servers.

	:::note
	There is no built-in Roblox signal for animation load completion.
	`Length` must be polled manually as property-changed signals do not fire for it.
	:::

	@param track   AnimationTrack -- The AnimationTrack to wait on.
	@param timeout number?        -- Max wait time in seconds. `nil` = wait indefinitely.
	@return boolean -- `true` if the track loaded within the timeout, `false` if it expired.
]=]
local function waitForTrackLength(track: AnimationTrack, timeout: number?): boolean
	if track.Length > 0 then return true end

	local thread = coroutine.running()

	task.defer(function()
		local start = os.clock()
		while true do
			if track.Length > 0 then
				if coroutine.status(thread) == "suspended" then
					task.spawn(thread, true)
				end
				return
			elseif timeout and os.clock() - start >= timeout then
				if coroutine.status(thread) == "suspended" then
					task.spawn(thread, false)
				end
				return
			end
			task.wait()
		end
	end)

	return coroutine.yield()
end

--[=[
	@private
	Fires a RemoteEvent to either a specific list of players or all clients.
	Used internally to dispatch `BUILD`, `PLAY`, `STOP`, and `CANCEL` messages.

	@param event   RemoteEvent -- The RemoteEvent to fire on.
	@param players {Player}?   -- Target players. `nil` fires to all clients.
	@param action  string      -- The action identifier (e.g. `"PLAY"`, `"STOP"`).
	@param id      string      -- The unique animation GUID.
	@param ...     any         -- Additional payload arguments forwarded to the receiver.
]=]
local function fireToClients(
	event   : RemoteEvent,
	players : { Player }?,
	action  : string,
	id      : string,
	...     : any
)
	if players then
		for _, player in ipairs(players) do
			event:FireClient(player, action, id, ...)
		end
	else
		event:FireAllClients(action, id, ...)
	end
end

-- // WrappedAnimation Methods

--[=[
	@private
	@method _ChangePlaybackState
	@within AnimationService

	Updates the internal playback state and deferred-fires `PlaybackStateChanged`
	with the previous and new values. Should only be called from within this service.

	@param new Enum.PlaybackState -- The state to transition into.
]=]
function MT.__index:_ChangePlaybackState(new: Enum.PlaybackState)
	local old = self._playbackState
	self._playbackState = new
	self.Signals.PlaybackStateChanged:FireDefer(old, new)
end

--[=[
	@method GetPlaybackState
	@within AnimationService

	Returns the current `Enum.PlaybackState` of this animation.
	Possible states: `Begin`, `Playing`, `Paused`, `Cancelled`, `Completed`.

	@return Enum.PlaybackState -- The current playback state.
]=]
function MT.__index:GetPlaybackState(): Enum.PlaybackState
	return self._playbackState
end

--[=[
	@method IsPlaying
	@within AnimationService

	Convenience check returning whether the animation is actively playing.
	Equivalent to `GetPlaybackState() == Enum.PlaybackState.Playing`.

	@return boolean -- `true` if the animation is currently in the `Playing` state.
]=]
function MT.__index:IsPlaying(): boolean
	return self._playbackState == Enum.PlaybackState.Playing
end

--[=[
	@method SetAnimationParams
	@within AnimationService

	Replaces the animation's configuration with new parameters. Any missing fields
	are filled in from `DEFAULT_ANIMATION_PARAMS`. Changes take effect on the
	next `Play()` call and do not affect a currently playing track.

	@param params AnimationParams -- The new parameters. Must be a non-nil table.
	@error "AnimationParams is invalid" -- Thrown if `params` is nil or not a table.
]=]
function MT.__index:SetAnimationParams(params: AnimationParams)
	Log:assert(params and typeof(params) == "table", "AnimationParams is invalid")
	self._params = TableUtil.reconcile(params, DEFAULT_ANIMATION_PARAMS)
end

--[=[
	@method Play
	@within AnimationService

	Plays the animation. Behaviour differs by runtime context:

	- **Server:** Sends a `BUILD` packet on first call, then a `PLAY` packet to
	  all clients (or only to `playOptions.Clients` if specified). The server-side
	  playback state transitions to `Playing` immediately.
	- **Client:** Calls `AnimationTrack:Play()` directly with the resolved fade
	  time, weight, and speed, then fires the `Played` signal.

	No-op if the animation is already in the `Playing` state.

	@param playOptions PlayOptions? -- Optional overrides for fade time, weight, speed, and target clients.
]=]
function MT.__index:Play(playOptions: PlayOptions?)
	if self:GetPlaybackState() == Enum.PlaybackState.Playing then return end

	local options = TableUtil.reconcile(playOptions or {}, DEFAULT_PLAY_OPTIONS)

	if RunService:IsServer() then
		if options.Clients then
			self._targetPlayers = options.Clients
		end

		local event = getNextRemoteEvent()

		if not self._firedToClients then
			self._firedToClients = true
			fireToClients(event, self._targetPlayers, "BUILD", self._uniqueId, {
				Rig       = self._rig,
				Animation = self._animationId,
				Params    = self._params,
			})
		end

		fireToClients(event, self._targetPlayers, "PLAY", self._uniqueId, options)
		self:_ChangePlaybackState(Enum.PlaybackState.Playing)
		return
	end

	if not self._track then return end

	self._track:Play(options.FadeTime, options.Weight, options.Speed)
	self:_ChangePlaybackState(Enum.PlaybackState.Playing)
	self.Signals.Played:Fire()
end

--[=[
	@method Stop
	@within AnimationService

	Stops the animation with an optional blend-out fade time.

	- **Server:** Sends a `STOP` packet to targeted or all clients.
	- **Client:** Calls `AnimationTrack:Stop()` directly if the track is playing.

	No-op if the animation is already in the `Paused` state.

	@param fadeTime number? -- Blend-out duration in seconds. Uses the track default if omitted.
]=]
function MT.__index:Stop(fadeTime: number?)
	if self._playbackState == Enum.PlaybackState.Paused then return end

	if RunService:IsServer() then
		local event = getNextRemoteEvent()
		fireToClients(event, self._targetPlayers, "STOP", self._uniqueId, fadeTime)
	else
		if self._track and self._track.IsPlaying then
			self._track:Stop(fadeTime)
		end
	end

	self:_ChangePlaybackState(Enum.PlaybackState.Paused)
end

--[=[
	@method Pause
	@within AnimationService

	Alias for `Stop()`. Provided for semantic clarity when the intent is to
	temporarily pause rather than fully end playback. Behaviour is currently identical.

	@param fadeTime number? -- Blend-out duration in seconds passed through to `Stop()`.
]=]
function MT.__index:Pause(fadeTime: number?)
	self:Stop(fadeTime)
end

--[=[
	@method Cancel
	@within AnimationService

	Permanently cancels the animation and destroys this `WrappedAnimation`.
	Unlike `Stop()`, a cancelled animation cannot be resumed.

	- **Server:** Sends a `CANCEL` packet to targeted or all clients before destroying.
	- **Client:** Falls through directly to `Destroy()`.

	No-op if already in the `Cancelled` state.
]=]
function MT.__index:Cancel()
	if self._playbackState == Enum.PlaybackState.Cancelled then return end

	if RunService:IsServer() then
		local event = getNextRemoteEvent()
		fireToClients(event, self._targetPlayers, "CANCEL", self._uniqueId)
	end

	self:_ChangePlaybackState(Enum.PlaybackState.Cancelled)
	self:Destroy()
end

--[=[
	@method Destroy
	@within AnimationService

	Cleans up all resources owned by this `WrappedAnimation` and invalidates the object.
	Should be called when the animation is permanently no longer needed.

	- **Server (not yet cancelled):** Delegates to `Cancel()` first to notify clients.
	- **Client:** Immediately stops the track (0s fade) then runs Trove cleanup.

	:::warning
	After `Destroy()` is called the object's metatable is removed and its table is
	cleared. Any further method calls on it will error.
	:::
]=]
function MT.__index:Destroy()
	if RunService:IsServer() and self._playbackState ~= Enum.PlaybackState.Cancelled then
		self:Cancel()
		return
	end

	if RunService:IsClient() and self._track then
		self._track:Stop(0)
	end

	self._trove:Destroy()
	setmetatable(self :: any, nil)
	table.clear(self :: any)
end

-- // Module Methods

--[=[
	Creates a new `WrappedAnimation` from an existing `Animator` instance.

	On the **client**, the animation track is loaded immediately and configured
	with the provided `AnimationParams`. On the **server**, track loading is
	deferred to the client via remote events on the first `Play()` call.

	If `AnimationParams.AutoPlay` is `true`, `Play()` is called automatically
	at the end of construction using `AnimationParams.AutoPlayOptions`.

	@param animator        Animator        -- The Animator to load the animation onto. Must be a valid Instance.
	@param animation       string | number -- The animation asset ID (number) or full URL string.
	@param animationParams AnimationParams? -- Optional configuration. Missing fields receive defaults.
	@error "animator is invalid" -- Thrown if `animator` is nil or not an Instance.
	@error "animation is nil"    -- Thrown if `animation` is nil.
	@return WrappedAnimation -- The newly created WrappedAnimation.
]=]
function Module:Create(
	animator        : Animator,
	animation       : string | number,
	animationParams : AnimationParams?
): WrappedAnimation
	Log:assert(animator and typeof(animator) == "Instance", "animator is invalid")
	Log:assert(animation, "animation is nil")

	local self = setmetatable({} :: self, MT)

	self._trove          = Trove.new()
	self._uniqueId       = HttpService:GenerateGUID(false)
	self._params         = TableUtil.reconcile(animationParams or {}, DEFAULT_ANIMATION_PARAMS)
	self._playbackState  = Enum.PlaybackState.Begin
	self._firedToClients = false
	self._animationId    = animation
	self._animator       = animator
	self._rig            = resolveRigFromAnimator(animator)

	self.Signals = {
		PlaybackStateChanged = self._trove:Construct(Signal),
	} :: any

	if RunService:IsClient() then
		local track = loadTrack(animator, animation)
		self._track = track

		track.Priority = self._params.AnimationPriority or Enum.AnimationPriority.Action
		track.Looped   = self._params.Looped or false
		track:AdjustSpeed(self._params.AnimationSpeed or 1)
		self._trove:Add(track)

		self.Signals.Played = self._trove:Construct(Signal)
		self.Signals.Paused = self._trove:Construct(Signal)
		self.Signals.Ended  = self._trove:Add(Signal.wrap(track.Ended))
	end

	if self._params.AutoPlay then
		self:Play(self._params.AutoPlayOptions)
	end

	return self
end

--[=[
	Creates a new `WrappedAnimation` from a rig `Instance`, automatically
	resolving or creating the required `Animator`.

	If the rig has no `Humanoid` or `AnimationController`, an `AnimationController`
	and `Animator` are created and parented onto it automatically.

	@param rig             Instance        -- The rig model to animate. Must be a valid Instance.
	@param animation       ValidAnimation  -- Animation ID (number), URL string, or Animation instance.
	@param animationParams AnimationParams? -- Optional configuration passed through to `Create()`.
	@error "rig is nil"       -- Thrown if `rig` is nil.
	@error "animation is nil" -- Thrown if `animation` is nil.
	@return WrappedAnimation -- The newly created WrappedAnimation.
]=]
function Module:CreateFromRig(
	rig             : Instance,
	animation       : ValidAnimation,
	animationParams : AnimationParams?
): WrappedAnimation
	Log:assert(rig, "rig is nil")
	Log:assert(animation, "animation is nil")
	local animator = getRigAnimator(rig) or createRigAnimator(rig)
	return self:Create(animator, animation, animationParams)
end

-- // Initialization

--[=[
	Initializes the `AnimationService`. Must be called exactly once before any
	animations are created or played.

	On the **client**, this connects all remote event listeners and prepares
	the `animationCache` to respond to `BUILD`, `PLAY`, `STOP`, and `CANCEL`
	messages sent from the server. Has no effect when called on the server.

	:::danger
	Calling `Init()` more than once creates duplicate remote event listeners,
	causing each server event to trigger animations multiple times per client.
	:::
]=]
function Module:Init()
	if not RunService:IsClient() then return end

	--[=[
		@private
		Constructs and caches a `WrappedAnimation` from a server-provided payload.
		Returns the existing cached entry if one already exists for `id`.

		@param id   string -- The unique animation GUID sent from the server.
		@param data any    -- Server payload containing `Rig`, `Animation`, and `Params` fields.
		@return WrappedAnimation? -- The built or cached animation, or `nil` if the rig is gone.
	]=]
	local function buildAnimation(id: string, data: any): WrappedAnimation?
		if animationCache[id] then
			return animationCache[id]
		end

		local rig = data.Rig
		if not rig or not rig.Parent then return nil end

		local animator = getRigAnimator(rig) or createRigAnimator(rig)
		local wrapped  = Module:Create(animator, data.Animation, data.Params)

		animationCache[id] = wrapped
		wrapped.Signals.Ended:Connect(function()
			animationCache[id] = nil
		end)

		return wrapped
	end

	local handlers: { [string]: (id: string, payload: any, ...any) -> () } = {

		-- Builds and caches the WrappedAnimation from the server payload.
		BUILD = function(id: string, payload: any)
			buildAnimation(id, payload)
		end,

		-- Plays a cached animation with the provided PlayOptions.
		PLAY = function(id: string, options: any)
			local anim = animationCache[id]
			if anim then anim:Play(options) end
		end,

		-- Stops a cached animation with an optional fade time.
		STOP = function(id: string, fadeTime: number?)
			local anim = animationCache[id]
			if anim then anim:Stop(fadeTime) end
		end,

		-- Destroys and removes a cached animation from the cache.
		CANCEL = function(id: string)
			local anim = animationCache[id]
			if anim then
				anim:Destroy()
				animationCache[id] = nil
			end
		end,
	}

	for _, event in playAnimationEvents do
		event.OnClientEvent:Connect(function(action: string, id: string, payload: any, ...)
			local handler = handlers[action]
			if handler then
				handler(id, payload, ...)
			else
				Log:warn(`Unknown animation action received: "{action}"`)
			end
		end)
	end
end

return Module :: AnimationService
