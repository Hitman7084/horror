extends Node3D

## Lightning Manager
## Attach to: LightningManager (Node3D) inside House
##
## Required child nodes:
##   LightningManager
##   ├── StormLight    (DirectionalLight3D)
##   ├── StormTimer    (Timer)
##   └── ThunderPlayer (AudioStreamPlayer)
##
## Inspector setup:
##   - Drag the WorldEnvironment node from the Scene panel into the "World Env" export slot.
##   - Assign a thunder AudioStream to ThunderPlayer > Stream in the Inspector.


# ── Exports ───────────────────────────────────────────────────────────────────

## Drag the WorldEnvironment node here in the Inspector.
@export var world_env: WorldEnvironment

## Drag the Player (CharacterBody3D) node here to enable thunder camera shake.
@export var player_node: Node3D

## Drag the player's Camera3D here to enable exposure shift during flash.
## The Camera3D must have a CameraAttributesPractical resource assigned to its
## Attributes property (Inspector > Camera3D > Attributes > New CameraAttributesPractical).
@export var player_camera: Camera3D


# ── Constants ─────────────────────────────────────────────────────────────────

const INTERVAL_MIN: float = 5.0  # seconds between lightning checks
const INTERVAL_MAX: float = 15.0

const LIGHTNING_CHANCE: float = 1  # 100% for now

const FLASH_ENERGY: float    = 6.0
const FLASH_DURATION: float  = 0.15   # seconds the full flash lasts
const FADE_DURATION: float   = 0.30   # seconds to fade back to 0

const AMBIENT_BASE: float    = 0.2    # default ambient energy
const AMBIENT_PEAK: float    = 0.6    # ambient during flash

const THUNDER_DELAY_MIN: float = 0.5  # seconds after flash before thunder
const THUNDER_DELAY_MAX: float = 1.2
const THUNDER_VOLUME_DB: float = -8.0

const EXPOSURE_BASE: float = 1.0   # camera exposure multiplier at rest
const EXPOSURE_PEAK: float = 1.5   # exposure boost at flash peak

const SHAKE_MAGNITUDE: float = 0.05  # metres of camera displacement on thunder
const SHAKE_DURATION:  float = 0.2   # seconds the shake lasts


# ── Node References ───────────────────────────────────────────────────────────

@onready var _storm_light:    DirectionalLight3D  = $StormLight
@onready var _storm_timer:    Timer               = $StormTimer
@onready var _thunder_player: AudioStreamPlayer   = $ThunderPlayer


# ── State ─────────────────────────────────────────────────────────────────────

var _lightning_pending: bool = false


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_storm_light.light_energy = 0.0

	_storm_timer.one_shot  = true
	_storm_timer.autostart = false
	_storm_timer.timeout.connect(_on_storm_timer_timeout)

	_thunder_player.volume_db = THUNDER_VOLUME_DB
	_thunder_player.autoplay  = false

	_schedule_next_check()


# ── Storm Logic ───────────────────────────────────────────────────────────────

func _schedule_next_check() -> void:
	_storm_timer.wait_time = randf_range(INTERVAL_MIN, INTERVAL_MAX)
	_storm_timer.start()


func _on_storm_timer_timeout() -> void:
	if not _lightning_pending and randf() < LIGHTNING_CHANCE:
		_trigger_lightning()

	_schedule_next_check()


func _trigger_lightning() -> void:
	_lightning_pending = true

	# Instant flash
	_storm_light.light_energy = FLASH_ENERGY

	if world_env:
		world_env.environment.ambient_light_energy = AMBIENT_PEAK

	# Ramp exposure up over the flash duration to simulate the intense light burst
	if player_camera and player_camera.attributes:
		var exp_tween: Tween = create_tween()
		exp_tween.tween_property(
			player_camera.attributes, "exposure_multiplier", EXPOSURE_PEAK, FLASH_DURATION
		)

	# Begin fade after flash duration
	get_tree().create_timer(FLASH_DURATION).timeout.connect(
		_begin_fade, CONNECT_ONE_SHOT
	)

	# Schedule thunder independently (must not overlap)
	var thunder_delay: float = randf_range(THUNDER_DELAY_MIN, THUNDER_DELAY_MAX)
	get_tree().create_timer(thunder_delay).timeout.connect(
		_play_thunder, CONNECT_ONE_SHOT
	)


func _begin_fade() -> void:
	# Fade StormLight energy from FLASH_ENERGY → 0 over FADE_DURATION
	var light_tween: Tween = create_tween()
	light_tween.tween_property(_storm_light, "light_energy", 0.0, FADE_DURATION)

	# Fade ambient back to base over the same duration
	if world_env:
		var amb_tween: Tween = create_tween()
		amb_tween.tween_property(
			world_env.environment,
			"ambient_light_energy",
			AMBIENT_BASE,
			FADE_DURATION
		)

	# Return exposure to base as the flash fades
	if player_camera and player_camera.attributes:
		var exp_tween: Tween = create_tween()
		exp_tween.tween_property(
			player_camera.attributes, "exposure_multiplier", EXPOSURE_BASE, FADE_DURATION
		)

	# Unlock after fade completes
	get_tree().create_timer(FADE_DURATION).timeout.connect(
		func() -> void: _lightning_pending = false,
		CONNECT_ONE_SHOT
	)


func _play_thunder() -> void:
	# Prevent overlap with a previous thunder sound still playing
	if _thunder_player.playing:
		return

	_thunder_player.play()

	# Shake the player's camera to sell the physical impact of the thunder
	if player_node and player_node.has_method("apply_shake"):
		player_node.apply_shake(SHAKE_MAGNITUDE, SHAKE_DURATION)
