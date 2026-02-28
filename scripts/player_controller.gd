extends CharacterBody3D

## First-Person Player Controller
##
## Required scene structure:
##   Player (CharacterBody3D)  ← attach this script
##   ├── CollisionShape3D
##   └── Head (Node3D)
##       └── Camera3D
##
## Required Input Map actions (Project > Project Settings > Input Map):
##   move_forward  → W
##   move_back     → S
##   move_left     → A
##   move_right    → D
##   jump          → Space
##   sprint        → Left Shift


# ── Mouse Look ────────────────────────────────────────────────────────────────

@export_group("Mouse Look")
@export var mouse_sensitivity: float = 0.002
## Maximum up/down look angle in degrees.
@export var pitch_limit: float = 89.0


# ── Movement ──────────────────────────────────────────────────────────────────

@export_group("Movement")
@export var walk_speed: float = 10.0       # m/s
@export var sprint_speed: float = 30.0     # m/s
## How quickly the player reaches target speed.
@export var acceleration: float = 10.0
## How quickly the player decelerates when no input is given.
@export var friction: float = 14.0


# ── Jump & Gravity ─────────────────────────────────────────────────────────────

@export_group("Jump and Gravity")
@export var jump_velocity: float = 5.0
## Units per second squared. Increase for a snappier fall.
@export var gravity_force: float = 20.0


# ── Stamina ───────────────────────────────────────────────────────────────────

@export_group("Stamina")
@export var max_stamina: float = 100.0
## Stamina drained per second while actively sprinting.
@export var stamina_drain_rate: float = 25.0
## Stamina restored per second when not sprinting.
@export var stamina_regen_rate: float = 15.0
## Seconds after stopping sprint before regeneration begins.
@export var stamina_regen_delay: float = 1.5


# ── Head Bob ──────────────────────────────────────────────────────────────────

@export_group("Head Bob")
## Bob cycles per second (relative to movement speed).
@export var bob_frequency: float = 2.0
## Peak vertical displacement in meters.
@export var bob_amplitude: float = 0.05
## How fast the bob offset interpolates to its target.
@export var bob_smoothing: float = 12.0


# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted every frame stamina changes. Connect to a UI bar or other system.
signal stamina_changed(current: float, maximum: float)


# ── Node References ───────────────────────────────────────────────────────────

@onready var _head: Node3D = $Head
@onready var _camera: Camera3D = $Head/Camera3D


# ── Internal State ────────────────────────────────────────────────────────────

var _stamina: float
var _stamina_regen_timer: float = 0.0
var _is_sprinting: bool = false

var _bob_time: float = 0.0
var _bob_offset: Vector3 = Vector3.ZERO

# ── Camera Shake ──────────────────────────────────────────────────────────────
var _shake_magnitude: float = 0.0
var _shake_remaining: float = 0.0
var _shake_total_duration: float = 1.0   # set by apply_shake; avoids div-by-zero
var _shake_offset: Vector3 = Vector3.ZERO


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_stamina = max_stamina
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_apply_mouse_look(event.relative)

	# Escape toggles mouse capture (handy during development)
	if event.is_action_pressed("ui_cancel"):
		var captured := Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
		Input.set_mouse_mode(
			Input.MOUSE_MODE_VISIBLE if captured else Input.MOUSE_MODE_CAPTURED
		)


func _physics_process(delta: float) -> void:
	_apply_gravity(delta)
	_handle_jump()
	_update_stamina(delta)
	_handle_movement(delta)
	_handle_head_bob(delta)
	_process_shake(delta)
	move_and_slide()


# ── Mouse Look ────────────────────────────────────────────────────────────────

func _apply_mouse_look(mouse_delta: Vector2) -> void:
	# Yaw: rotate the whole body left/right
	rotate_y(-mouse_delta.x * mouse_sensitivity)

	# Pitch: rotate only the head up/down, clamped to prevent flipping
	_head.rotate_x(-mouse_delta.y * mouse_sensitivity)
	_head.rotation.x = clamp(
		_head.rotation.x,
		deg_to_rad(-pitch_limit),
		deg_to_rad(pitch_limit)
	)


# ── Gravity & Jump ─────────────────────────────────────────────────────────────

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity_force * delta


func _handle_jump() -> void:
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity


# ── Stamina ───────────────────────────────────────────────────────────────────

func _update_stamina(delta: float) -> void:
	var wants_sprint: bool = Input.is_action_pressed("sprint")
	var has_input: bool = _get_input_direction().length_squared() > 0.0

	_is_sprinting = wants_sprint and has_input and _stamina > 0.0

	if _is_sprinting:
		_stamina = maxf(_stamina - stamina_drain_rate * delta, 0.0)
		_stamina_regen_timer = stamina_regen_delay          # reset delay on every sprint frame
	else:
		if _stamina_regen_timer > 0.0:
			_stamina_regen_timer -= delta
		else:
			_stamina = minf(_stamina + stamina_regen_rate * delta, max_stamina)

	stamina_changed.emit(_stamina, max_stamina)


# ── Movement ──────────────────────────────────────────────────────────────────

func _get_input_direction() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


func _handle_movement(delta: float) -> void:
	var input_dir: Vector2 = _get_input_direction()

	# Project 2-D input onto the player's local XZ plane for directional movement
	var wish_dir: Vector3 = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var target_speed: float = sprint_speed if _is_sprinting else walk_speed

	if wish_dir != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, wish_dir.x * target_speed, acceleration * delta)
		velocity.z = move_toward(velocity.z, wish_dir.z * target_speed, acceleration * delta)
	else:
		# Decelerate smoothly when no directional input
		velocity.x = move_toward(velocity.x, 0.0, friction * delta)
		velocity.z = move_toward(velocity.z, 0.0, friction * delta)


# ── Head Bob ──────────────────────────────────────────────────────────────────

func _handle_head_bob(delta: float) -> void:
	var horizontal_speed: float = Vector2(velocity.x, velocity.z).length()
	var grounded: bool = is_on_floor()

	if horizontal_speed > 0.5 and grounded:
		# Advance the bob cycle proportional to how fast the player is moving
		_bob_time += delta * horizontal_speed * bob_frequency

		var target_offset := Vector3(
			cos(_bob_time) * bob_amplitude * 0.5,   # subtle side-sway
			abs(sin(_bob_time)) * bob_amplitude,     # vertical bounce (always upward arc)
			0.0
		)
		_bob_offset = _bob_offset.lerp(target_offset, bob_smoothing * delta)
	else:
		# Smoothly return the camera to the neutral position when still or airborne
		_bob_offset = _bob_offset.lerp(Vector3.ZERO, bob_smoothing * delta)

	_camera.position = _bob_offset + _shake_offset


# ── Camera Shake ──────────────────────────────────────────────────────────────

## Call this from any external node (e.g. LightningManager) to trigger a shake.
## magnitude: peak displacement in metres. duration: total shake time in seconds.
func apply_shake(magnitude: float, duration: float) -> void:
	_shake_magnitude      = magnitude
	_shake_total_duration = maxf(duration, 0.001)
	_shake_remaining      = duration


func _process_shake(delta: float) -> void:
	if _shake_remaining > 0.0:
		_shake_remaining -= delta
		# Decay factor makes the shake taper off smoothly toward the end
		var decay: float = _shake_remaining / _shake_total_duration
		_shake_offset = Vector3(
			randf_range(-_shake_magnitude, _shake_magnitude) * decay,
			randf_range(-_shake_magnitude, _shake_magnitude) * decay,
			0.0
		)
	else:
		# Lerp back to zero so there is no hard pop when shake ends
		_shake_offset = _shake_offset.lerp(Vector3.ZERO, 20.0 * delta)
