extends Node3D

# ── Inspector Slots ────────────────────────────────────────────────────────────
@export var door_hinge: Node3D                    ## The AnimatableBody3D that rotates (door pivot)
@export var door_handle: Node3D                   ## Handle node that rotates on interact
@export var door_area: Area3D                     ## Area3D for player proximity detection
@export var door_open_audio: AudioStreamPlayer3D  ## Sound played when the door opens
@export var door_close_audio: AudioStreamPlayer3D ## Sound played when the door closes

@export var open_angle_deg: float  = 90.0  ## How far the door swings open (degrees)
@export var open_duration: float   = 1.2   ## Seconds to swing open
@export var close_duration: float  = 1.0   ## Seconds to swing closed

@export var handle_rotate_deg: float = -45.0  ## How far the handle rotates (negative = downward)
@export var handle_duration: float   = 0.25   ## Seconds for handle rotation

# ── State ──────────────────────────────────────────────────────────────────────
enum State { CLOSED, OPENING, OPEN, CLOSING }
var _state: State = State.CLOSED
var _player_nearby: bool = false
var _tween: Tween = null

# ── Lifecycle ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	print("[Door] _ready — node: ", name)
	print("[Door] door_hinge: ", door_hinge)
	print("[Door] door_handle: ", door_handle)
	print("[Door] door_open_audio: ", door_open_audio)
	print("[Door] door_close_audio: ", door_close_audio)
	print("[Door] door_area: ", door_area)

	assert(door_hinge      != null, "door_interaction: assign door_hinge in Inspector")
	assert(door_open_audio  != null, "door_interaction: assign door_open_audio in Inspector")
	assert(door_close_audio != null, "door_interaction: assign door_close_audio in Inspector")

	if door_area:
		door_area.body_entered.connect(_on_body_entered)
		door_area.body_exited.connect(_on_body_exited)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("player_interact"):
		var can_interact := _player_nearby if door_area != null else true
		print("[Door] F pressed — can_interact: ", can_interact, " | player_nearby: ", _player_nearby, " | state: ", State.keys()[_state])
		if can_interact:
			_toggle()

# ── Toggle ─────────────────────────────────────────────────────────────────────
func _toggle() -> void:
	print("[Door] _toggle called — current state: ", State.keys()[_state])
	match _state:
		State.CLOSED, State.CLOSING:
			_animate(open_angle_deg, open_duration, door_open_audio)
			_state = State.OPENING
		State.OPEN, State.OPENING:
			_animate(0.0, close_duration, door_close_audio)
			_state = State.CLOSING

# ── Animation ──────────────────────────────────────────────────────────────────
func _animate(target_deg: float, duration: float, audio: AudioStreamPlayer3D) -> void:
	print("[Door] _animate — target_deg: ", target_deg, " | duration: ", duration)
	if audio and not audio.playing:
		audio.play()

	if _tween and _tween.is_valid():
		_tween.kill()

	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.set_trans(Tween.TRANS_CUBIC)

	# Step 1 — rotate handle down (press gesture)
	if door_handle:
		_tween.tween_property(door_handle, "basis",
			Basis(Vector3.RIGHT, deg_to_rad(handle_rotate_deg)), handle_duration)

	# Step 2 — swing the door
	_tween.tween_property(door_hinge, "basis",
		Basis(Vector3.UP, deg_to_rad(target_deg)), duration)

	_tween.tween_callback(_on_tween_done)

func _on_tween_done() -> void:
	_state = State.OPEN if _state == State.OPENING else State.CLOSED
	print("[Door] tween done — new state: ", State.keys()[_state])

	# Return handle to resting position after door finishes
	if door_handle:
		var t := create_tween()
		t.set_ease(Tween.EASE_OUT)
		t.set_trans(Tween.TRANS_CUBIC)
		t.tween_property(door_handle, "basis", Basis.IDENTITY, handle_duration)

# ── Proximity ──────────────────────────────────────────────────────────────────
func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_nearby = true

func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_nearby = false
