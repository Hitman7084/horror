class_name NoiseDetector
extends Area3D

## ── NoiseDetector ─────────────────────────────────────────────────────────────
##
## Area3D noise detection zone for the RitualWatcher AI.
## Attach to a child Area3D node with a SphereShape3D CollisionShape3D.
##
## Required scene structure:
##   NoiseDetector (Area3D)        ← attach this script
##   └── CollisionShape3D
##        └── SphereShape3D        (set radius to 70.0 in Inspector)
##
## Physics layers:
##   - collision_layer: 0 (this detector is not detected by others)
##   - collision_mask:  set to match the player's physics layer (default: 1)
##
## The parent RitualWatcher calls check_noise(blackboard) each physics frame.
## The sound target is cleared by the AI's navigate_to_sound action, not here.


# ── Constants ──────────────────────────────────────────────────────────────────

## Minimum noise level that triggers AI investigation.
## Player noise levels: 0=idle, 1=walking, 2=jumping, 3=sprinting
const NOISE_THRESHOLD: int = 2


# ── State ──────────────────────────────────────────────────────────────────────

## All player bodies currently inside the detection sphere.
var _players_in_range: Array = []  # Array[CharacterBody3D]


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	monitoring  = true
	monitorable = false

	# Do not occupy a physics layer — this area is a pure sensor.
	collision_layer = 0
	# Mask layer 1 matches the default player physics layer.
	# Adjust if the player's CollisionObject3D uses a different layer.
	collision_mask  = 1

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


# ── Signal Handlers ───────────────────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		_players_in_range.append(body)


func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group("player"):
		_players_in_range.erase(body)


# ── Public API ────────────────────────────────────────────────────────────────

## Called each physics frame by RitualWatcher after the authority check.
## Updates blackboard["has_sound_target"] and ["last_heard_sound_position"]
## if any player inside the zone is making enough noise.
func check_noise(blackboard: Dictionary) -> void:
	for player in _players_in_range:
		if not is_instance_valid(player):
			continue

		# Use get() so the system degrades gracefully if the property is missing.
		var noise_level: int = player.get("current_noise_level") if \
				"current_noise_level" in player else 0

		if noise_level >= NOISE_THRESHOLD:
			blackboard["has_sound_target"]          = true
			blackboard["last_heard_sound_position"] = player.global_position
			# Only the loudest first threshold matters per frame; return early.
			return
	# No players are loud enough. The sound target is intentionally NOT cleared
	# here — it persists until the AI investigates and reaches the location.
