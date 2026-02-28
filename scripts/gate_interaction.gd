extends Node3D

# ── Inspector Slots ────────────────────────────────────────────────────────────
@export var left_hinge: Node3D               ## Pivot node at left gate's hinge
@export var right_hinge: Node3D              ## Pivot node at right gate's hinge
@export var gate_area: Area3D                ## Area3D for player proximity
@export var gate_audio: AudioStreamPlayer3D  ## Assign a creak / metal sound

@export var open_angle_deg: float  = 70  ## How far each panel swings open
@export var open_duration: float   = 4.5   ## Seconds to open
@export var close_duration: float  = 4.5    ## Seconds to close

# ── State ──────────────────────────────────────────────────────────────────────
enum State { CLOSED, OPENING, OPEN, CLOSING }
var _state: State = State.CLOSED
var _player_nearby: bool = false
var _tween: Tween = null

# ── Lifecycle ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	# print("[Gate] _ready fired. left_hinge=", left_hinge, " right_hinge=", right_hinge, " gate_audio=", gate_audio, " gate_area=", gate_area)
	assert(left_hinge  != null, "gate_interaction: assign left_hinge in Inspector")
	assert(right_hinge != null, "gate_interaction: assign right_hinge in Inspector")
	assert(gate_audio  != null, "gate_interaction: assign gate_audio in Inspector")

	if gate_area:
		gate_area.body_entered.connect(_on_body_entered)
		gate_area.body_exited.connect(_on_body_exited)
		# print("[Gate] GateArea signals connected")

func _unhandled_input(event: InputEvent) -> void:
	# if event.is_action_pressed("gate_interact"):
	# 	print("[Gate] F pressed | player_nearby=", _player_nearby, " | gate_area assigned=", gate_area != null)
	var can_interact := _player_nearby if gate_area != null else true
	if can_interact and event.is_action_pressed("gate_interact"):
		_toggle()

# ── Toggle ─────────────────────────────────────────────────────────────────────
func _toggle() -> void:
	# print("[Gate] _toggle called | state=", State.keys()[_state])
	match _state:
		State.CLOSED, State.CLOSING:
			_animate(open_angle_deg, open_duration)
			_state = State.OPENING
		State.OPEN, State.OPENING:
			_animate(0.0, close_duration)
			_state = State.CLOSING

# ── Animation ──────────────────────────────────────────────────────────────────
func _animate(target_deg: float, duration: float) -> void:
	if gate_audio and not gate_audio.playing:
		gate_audio.play()

	if _tween and _tween.is_valid():
		_tween.kill()

	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.set_trans(Tween.TRANS_CUBIC)

	var left_target  := Basis(Vector3.UP, deg_to_rad(target_deg-180))
	var right_target := Basis(Vector3.UP, deg_to_rad(-target_deg))

	_tween.tween_property(left_hinge,  "basis", left_target,  duration)
	_tween.tween_property(right_hinge, "basis", right_target, duration)
	_tween.chain().tween_callback(_on_tween_done)

func _on_tween_done() -> void:
	_state = State.OPEN if _state == State.OPENING else State.CLOSED

# ── Proximity ──────────────────────────────────────────────────────────────────
func _on_body_entered(body: Node3D) -> void:
	# print("[Gate] body_entered: ", body.name, " | in group player=", body.is_in_group("player"))
	if body.is_in_group("player"):
		_player_nearby = true

func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_nearby = false
