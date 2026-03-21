# AnimationPackage

A server-client animation management system for Roblox. Wraps `AnimationTrack` into a clean `WrappedAnimation` object with signals, lifecycle management, and automatic client replication via remote events.

---

## Folder Structure

```
src/
├── AnimationService.lua   ← Main module
└── Packages/
    ├── Signal.lua         ← Custom signal implementation
    ├── Butler.lua         ← Resource/lifecycle manager
    ├── TypedRemote.lua    ← Typed RemoteEvent/Function wrappers
    ├── TableUtil.lua      ← Table utility (reconcile)
    └── Logger.lua         ← Prefixed logging + assertions
```

---

## Setup

### With Rojo
1. Clone this repo
2. Run `rojo serve default.project.json`
3. Sync into Studio — the package lands in `ReplicatedStorage.AnimationPackage`

### Manual
Copy the `src` folder into `ReplicatedStorage` and rename it to `AnimationPackage`.

---

## Usage

```lua
-- In a server Script
local AnimationService = require(game.ReplicatedStorage.AnimationPackage.AnimationService)
AnimationService:Init() -- Call once on both server and client

-- Create from a rig
local anim = AnimationService:CreateFromRig(character, 123456789, {
    AnimationPriority = Enum.AnimationPriority.Action,
    Looped = false,
})

-- Play to all clients
anim:Play({ FadeTime = 0.2 })

-- Listen to state changes
anim.Signals.PlaybackStateChanged:Connect(function(old, new)
    print("State:", old, "->", new)
end)

-- Stop and clean up
anim:Stop(0.1)
anim:Destroy()
```

```lua
-- In a LocalScript (client)
local AnimationService = require(game.ReplicatedStorage.AnimationPackage.AnimationService)
AnimationService:Init() -- Required on client to receive server events
```

---

## API

### `AnimationService`

| Method | Description |
|--------|-------------|
| `Init()` | Initializes the service. Call once on both server and client. |
| `Create(animator, animation, params?)` | Creates a `WrappedAnimation` from an `Animator`. |
| `CreateFromRig(rig, animation, params?)` | Creates a `WrappedAnimation` from a rig model. |

### `WrappedAnimation`

| Method | Description |
|--------|-------------|
| `Play(options?)` | Plays the animation. |
| `Stop(fadeTime?)` | Stops the animation. |
| `Pause(fadeTime?)` | Alias for `Stop()`. |
| `Cancel()` | Permanently cancels and destroys the animation. |
| `Destroy()` | Cleans up all resources. |
| `IsPlaying()` | Returns `true` if currently playing. |
| `GetPlaybackState()` | Returns the current `Enum.PlaybackState`. |
| `SetAnimationParams(params)` | Replaces animation configuration. |

### Signals

| Signal | Fires when... |
|--------|--------------|
| `Played` | Animation starts playing (client only) |
| `Paused` | *(reserved)* |
| `Ended` | AnimationTrack ends (client only) |
| `PlaybackStateChanged(old, new)` | Playback state transitions |

---

## Types

```lua
type AnimationParams = {
    AnimationPriority : Enum.AnimationPriority?,
    AnimationSpeed    : number?,
    Looped            : boolean?,
    AutoPlay          : boolean?,
    AutoPlayOptions   : PlayOptions?,
}

type PlayOptions = {
    FadeTime : number?,
    Weight   : number?,
    Speed    : number?,
    Clients  : { Player }?,  -- nil = all clients
}
```

---

## Dependencies

All dependencies are self-contained in the `Packages/` folder — no external installs required.

| Package | Source |
|---------|--------|
| `Butler` | Internal |
| `Signal` | Custom high-performance implementation |
| `TypedRemote` | Internal |
| `TableUtil` | Adapted from [Stephen Leitnick](https://github.com/Sleitnick/RbxUtil) |
| `Logger` | Internal (@crusherfire) |
