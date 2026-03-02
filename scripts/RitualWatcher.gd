class_name RitualWatcher
extends CharacterBody3D

# ── Floor IDs ─────────────────────────────────────────────────────────────────
## Numeric identifiers returned by _get_floor(). Stored in the blackboard so
## every branch can read them without recomputing per-frame.
const FLOOR_BASEMENT:   int = 0   # Y < basement_ceiling_y
const FLOOR_TRANSITION: int = 1   # on stairs (between the two thresholds)
const FLOOR_GROUND:     int = 2   # Y > ground_floor_y

## ── RitualWatcher AI Controller ───────────────────────────────────────────────
##
## Advanced horror AI using a Behaviour Tree architecture with a self-learning
## Cognitive Map.  The AI builds a spatial grid through raycasting as it explores,
## discovers stairs by detecting floor slope, and pathfinds through discovered
## walkable cells using AStarGrid2D.
##
## Behaviours (priority order):
##   1. HUNT_PLAYER   — chase the player with Weeping Angel freeze mechanic
##   2. CROSS_FLOOR   — pursue the player across floors via discovered stairs
##   3. INVESTIGATE_SOUND — move toward the last heard loud noise
##   4. EXPLORE       — frontier-based exploration of unmapped territory
##
## Required scene structure:
##   RitualWatcher (CharacterBody3D)   <- attach this script
##   ├── CollisionShape3D              (CapsuleShape3D, r=0.4, h=1.8)
##   ├── MeshInstance3D                (AI visual mesh)
##   ├── BehaviorTree (Node)           <- attach BehaviorTree.gd
##   ├── NoiseDetector (Area3D)        <- attach NoiseDetector.gd
##   │   └── CollisionShape3D          (SphereShape3D, radius=70.0)
##   └── ExploreTimer (Timer)
##
## Inspector setup:
##   • player_node  → drag the Player (CharacterBody3D) from the scene
##   • Verify the player is in the "player" group (Project > Groups)


# ── Exports ────────────────────────────────────────────────────────────────────

@export_group("References")
## Drag the Player CharacterBody3D here in the Inspector.
@export var player_node: CharacterBody3D

@export_group("Detection")
## Distance at which the AI begins hunting the player (m).
@export var hunt_enter_distance: float = 10.0
## Hysteresis distance — AI stops hunting only when player moves beyond this (m).
@export var hunt_exit_distance: float  = 15.0
## Camera-to-AI dot product threshold that counts as "being looked at".
## 0.6 means the player must be facing within ~53° of the AI.
@export var look_dot_threshold: float  = 0.6
## Distance at which the player is caught (m).
@export var catch_distance: float      = 2.0
## Distance at which a sound investigation target is considered "reached" (m).
@export var sound_reach_distance: float = 3.0
## Y below this is treated as the basement floor.
@export var basement_ceiling_y: float = -1.0
## Y above this is treated as the ground floor.
@export var ground_floor_y: float     =  1.0

@export_group("Movement")
## Speed while hunting the player (m/s).
@export var hunt_speed: float        = 5.0
## Speed while investigating a sound (m/s).
@export var investigate_speed: float = 3.0
## Speed while exploring randomly (m/s).
@export var explore_speed: float     = 2.0
## How quickly the AI rotates toward its movement direction (higher = snappier).
@export var rotation_speed: float    = 5.0
## Gravity force applied manually each frame (must match Jolt world gravity).
@export var gravity_force: float     = 20.0

@export_group("Cognitive Map")
## How often the AI scans its surroundings (seconds).
@export var sense_interval: float = 0.25
## Length of each sensing ray (metres).
@export var sense_ray_length: float = 12.0
## Number of horizontal sensing rays (evenly spaced around 360°).
@export var sense_ray_count: int = 12
## Minimum slope angle (degrees) to classify as stairs/ramp.
@export var stair_slope_threshold: float = 10.0


# ── Node References ────────────────────────────────────────────────────────────

@onready var _behavior_tree:  BehaviorTree      = $BehaviorTree
@onready var _noise_detector: NoiseDetector     = $NoiseDetector
@onready var _explore_timer:  Timer             = $ExploreTimer


# ── Blackboard ────────────────────────────────────────────────────────────────
##
## Shared data dictionary passed by reference to all action/condition callables.
## In GDScript 4, Dictionaries are reference types — closures capture the same
## underlying object, so every write here is immediately visible everywhere.

var blackboard: Dictionary = {
	"player_ref":                 null,
	"last_known_player_position": Vector3.ZERO,
	"last_heard_sound_position":  Vector3.ZERO,
	"is_player_visible":          false,
	"distance_to_player":         INF,
	"is_being_looked_at":         false,
	"has_sound_target":           false,
	"is_hunting":                 false,  # internal hysteresis flag
	"ai_floor":                   FLOOR_BASEMENT,
	"player_floor":               FLOOR_GROUND,
	"cross_floor_pursue":         false,  # true while heading to/climbing stairs
}


# ── Internal State ────────────────────────────────────────────────────────────

## Target speed applied this frame. Set by whichever branch is active.
var _current_speed: float = 0.0

## Cached Camera3D from the player scene. Set in _ready(), lazily refreshed.
var _player_camera: Camera3D = null

# ── Cognitive Map ────────────────────────────────────────────────────────────

## Per-floor grid maps built through raycasting as the AI explores.
var _basement_map: CognitiveMap
var _ground_map: CognitiveMap

## Sensing cooldown timer – counts up to sense_interval.
var _sense_timer: float = 0.0

## Cached A* path the AI is currently following (XZ waypoints).
var _current_path: PackedVector2Array = PackedVector2Array()
## Index of the next waypoint in _current_path.
var _path_index: int = 0
## The world position the current path was computed toward (for staleness detection).
var _path_target: Vector3 = Vector3.ZERO
## Time the last path was computed (for hunt recompute throttle).
var _path_compute_time: float = 0.0

# ── Stuck Detection ────────────────────────────────────────────────────────
## Accumulates time the AI has been nearly stationary while trying to move.
var _stuck_timer: float = 0.0
## Threshold: if actual XZ velocity is below this while speed > 0, AI is stuck.
const STUCK_VELOCITY_THRESHOLD: float = 0.3
## How long (seconds) the AI must be stuck before forcing a path recompute.
const STUCK_TIME_THRESHOLD: float = 0.4

# ── Debug ──────────────────────────────────────────────────────────────────────
## Accumulates delta; prints a status snapshot every DEBUG_INTERVAL seconds.
var _debug_timer: float = 0.0
const DEBUG_INTERVAL: float = 2.0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# All AI logic runs only on the authority peer.
	# In single-player the local instance is always the authority.
	if not is_multiplayer_authority():
		print("[RW] Not authority — physics disabled.")
		set_physics_process(false)
		return

	assert(player_node != null,
		"RitualWatcher: assign 'player_node' in the Inspector before running.")

	blackboard["player_ref"] = player_node
	print("[RW] _ready() — player_node: ", player_node.name)

	# Cache the player's first-person camera for look detection.
	_player_camera = player_node.get_node_or_null("Head/Camera3D")
	print("[RW] Camera found: ", _player_camera != null,
		"  path tried: Head/Camera3D")

	# Ramp traversal: 45-degree slope needs floor_max_angle above default.
	floor_max_angle = deg_to_rad(50.0)
	# Keep speed constant on slopes so AI pursuit speed is predictable.
	floor_constant_speed = true
	# Snap-down keeps the AI grounded when descending the ramp.
	floor_snap_length = 0.4

	# Initialize cognitive maps (one per floor).
	_basement_map = CognitiveMap.new()
	_ground_map   = CognitiveMap.new()

	# Exploration timer — triggers new explore target periodically.
	_explore_timer.one_shot  = false
	_explore_timer.autostart = false
	_explore_timer.timeout.connect(_pick_explore_target)
	_explore_timer.wait_time = randf_range(4.0, 6.0)
	_explore_timer.start()

	# Build and activate the behaviour tree.
	_build_behavior_tree()
	print("[RW] _ready() complete. Cognitive map initialized, behaviour tree built.")


func _physics_process(delta: float) -> void:
	# Authority guard — never run AI logic on non-authority peers.
	if not is_multiplayer_authority():
		return

	_update_blackboard()                    # 1. refresh sensor values
	_noise_detector.check_noise(blackboard) # 2. poll the sound detector
	_sense_environment(delta)               # 3. raycast + update cognitive map (throttled)
	_behavior_tree.tick()                   # 4. evaluate tree (sets speed, computes path)
	_apply_movement(delta)                  # 5. follow cognitive map path + gravity
	move_and_slide()                        # 6. apply velocity with Jolt physics

	# ── Throttled debug snapshot ──────────────────────────────────────────────
	_debug_timer += delta
	if _debug_timer >= DEBUG_INTERVAL:
		_debug_timer = 0.0
		var active_map := _get_active_map()
		print("────────── [RitualWatcher] DEBUG ──────────")
		print("  dist_to_player : ", snappedf(blackboard["distance_to_player"], 0.1))
		print("  is_hunting     : ", blackboard["is_hunting"])
		print("  is_looked_at   : ", blackboard["is_being_looked_at"])
		print("  has_sound_tgt  : ", blackboard["has_sound_target"])
		print("  current_speed  : ", _current_speed)
		print("  velocity       : ", velocity.snapped(Vector3.ONE * 0.01))
		print("  on_floor       : ", is_on_floor())
		print("  ai_floor       : ", blackboard["ai_floor"],
			"  (0=basement 1=stairs 2=ground)")
		print("  player_floor   : ", blackboard["player_floor"],
			"  (0=basement 1=stairs 2=ground)")
		print("  cross_floor    : ", blackboard["cross_floor_pursue"])
		print("  map walkable   : ", active_map.get_walkable_count())
		print("  map stairs     : ", active_map.get_stair_count())
		print("  path length    : ", _current_path.size(),
			"  index: ", _path_index)
		print("───────────────────────────────────────────")


# ── Blackboard Sensor Update ──────────────────────────────────────────────────

func _update_blackboard() -> void:
	if not is_instance_valid(player_node):
		return
	blackboard["distance_to_player"] = global_position.distance_to(
		player_node.global_position
	)
	blackboard["ai_floor"]     = _get_floor(global_position.y)
	blackboard["player_floor"] = _get_floor(player_node.global_position.y)

	# Cross-floor pursuit trigger: player jumps (or sprints) while on a different floor.
	if blackboard["player_floor"] != blackboard["ai_floor"] \
			and not blackboard["is_hunting"] \
			and not blackboard["cross_floor_pursue"]:
		var noise: int = player_node.get("current_noise_level") \
				if "current_noise_level" in player_node else 0
		if noise >= 2:
			blackboard["cross_floor_pursue"] = true
			print("[RW] Cross-floor pursue triggered (noise=", noise, ")")


## Returns the floor ID constant for a given world Y position.
func _get_floor(y: float) -> int:
	if y < basement_ceiling_y:
		return FLOOR_BASEMENT
	elif y > ground_floor_y:
		return FLOOR_GROUND
	else:
		return FLOOR_TRANSITION


# ── Cognitive Map: Active Map ────────────────────────────────────────────────

## Returns the cognitive map for the AI's current floor.
func _get_active_map() -> CognitiveMap:
	if blackboard["ai_floor"] == FLOOR_BASEMENT:
		return _basement_map
	return _ground_map


# ── Cognitive Map: Sensing ───────────────────────────────────────────────────

## Cast rays in all directions to discover walkable space and walls.
## Throttled by sense_interval to avoid per-frame cost.
func _sense_environment(delta: float) -> void:
	_sense_timer += delta
	if _sense_timer < sense_interval:
		return
	_sense_timer = 0.0

	var active_map := _get_active_map()
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin := global_position
	var current_time: float = Time.get_ticks_msec() / 1000.0

	# Mark the AI's current position as walkable.
	active_map.mark_walkable(origin)
	active_map.mark_visited(origin, current_time)

	# Build exclusion list: AI itself + player.
	var exclude_rids: Array[RID] = [get_rid()]
	if is_instance_valid(player_node):
		exclude_rids.append(player_node.get_rid())

	# Cast evenly-spaced horizontal rays.
	for i in range(sense_ray_count):
		var angle: float = float(i) / float(sense_ray_count) * TAU
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var end := origin + direction * sense_ray_length

		var params := PhysicsRayQueryParameters3D.create(origin, end)
		params.exclude = exclude_rids

		var hit: Dictionary = space.intersect_ray(params)
		if hit:
			# Open space from origin to just before the hit → walkable.
			active_map.mark_ray_walkable(origin, hit["position"])
			# The hit surface cell → blocked.
			active_map.mark_blocked(hit["position"])
		else:
			# Entire ray length is open space.
			active_map.mark_ray_walkable(origin, end)

	# ── Stair / ramp detection ───────────────────────────────────────────────
	if is_on_floor():
		var floor_normal := get_floor_normal()
		var slope_angle := acos(floor_normal.dot(Vector3.UP))
		if slope_angle > deg_to_rad(stair_slope_threshold):
			active_map.mark_stair(origin)
			# Also mark on the OTHER floor's map so cross-floor pathfinding
			# knows where to find the stair entry from either side.
			if active_map == _basement_map:
				_ground_map.mark_stair(origin)
			else:
				_basement_map.mark_stair(origin)


# ── Behaviour Tree Construction ───────────────────────────────────────────────

func _build_behavior_tree() -> void:

	# ── HUNT_PLAYER ───────────────────────────────────────────────────────────
	# Activates when the player is within hunt_enter_distance on the same floor.
	# Weeping Angel: the AI freezes while the player's camera is facing it.
	var hunt_seq := SequenceNode.new([
		ConditionNode.new(_condition_should_hunt),
		ActionNode.new(_action_update_look_detection),
		ActionNode.new(_action_hunt_movement),
		ActionNode.new(_action_check_caught),
	])

	# ── INVESTIGATE_SOUND ─────────────────────────────────────────────────────
	# Activates when a loud noise has been detected and a position recorded.
	var investigate_seq := SequenceNode.new([
		ConditionNode.new(func() -> bool: return blackboard["has_sound_target"]),
		ActionNode.new(_action_navigate_to_sound),
	])

	# ── CROSS_FLOOR_PURSUIT ────────────────────────────────────────────────────
	# Activates when the player makes noise (jump/sprint) on a different floor.
	# AI pathfinds to discovered stairs using the cognitive map.
	var cross_floor_seq := SequenceNode.new([
		ConditionNode.new(_condition_cross_floor_pursue),
		ActionNode.new(_action_cross_floor_pursue),
	])

	# ── EXPLORE ───────────────────────────────────────────────────────────────
	# Fallback: frontier-based exploration of unmapped territory.
	var explore_seq := SequenceNode.new([
		ActionNode.new(_action_random_exploration),
	])

	# Root Selector tries branches in priority order.
	var root := SelectorNode.new([hunt_seq, cross_floor_seq, investigate_seq, explore_seq])
	_behavior_tree.set_root(root)


# ── Conditions ────────────────────────────────────────────────────────────────

## Hysteresis gate: engage hunt at <=hunt_enter_distance, hold until >hunt_exit_distance.
## Prevents the AI from rapidly toggling in/out of hunt at the boundary.
func _condition_should_hunt() -> bool:
	# Never hunt across floors — AI cannot see or reach the player through ceilings.
	if blackboard["ai_floor"] != blackboard["player_floor"]:
		if blackboard["is_hunting"]:
			blackboard["is_hunting"] = false
			_clear_path()
			_pick_explore_target()
		return false

	var dist: float = blackboard["distance_to_player"]

	if blackboard["is_hunting"]:
		# Currently hunting — keep hunting unless the player has escaped far enough.
		if dist > hunt_exit_distance:
			blackboard["is_hunting"] = false
			_clear_path()
			_pick_explore_target()
			return false
		return true
	else:
		# Not currently hunting — begin only if player is close enough.
		if dist <= hunt_enter_distance:
			blackboard["is_hunting"] = true
			_clear_path()
			return true
		return false


# ── Actions: Hunt Branch ──────────────────────────────────────────────────────

## Weeping Angel logic.
## Checks whether the player's camera is directly facing the AI and whether
## an unobstructed line of sight exists. Updates blackboard["is_being_looked_at"].
## Always returns SUCCESS — it is a sensor update, not a decision.
func _action_update_look_detection() -> int:
	# Lazily refresh the camera reference if it was lost.
	if not is_instance_valid(_player_camera):
		_player_camera = player_node.get_node_or_null("Head/Camera3D")
		if not _player_camera:
			blackboard["is_being_looked_at"] = false
			return BaseNode.Status.SUCCESS

	# In Godot 4 the camera's local -Z axis is its world-space forward direction.
	var cam_forward: Vector3 = -_player_camera.global_transform.basis.z
	var dir_to_ai: Vector3   = (global_position - _player_camera.global_position).normalized()
	var dot: float           = cam_forward.dot(dir_to_ai)

	if dot > look_dot_threshold:
		# The player is roughly facing the AI — confirm with a physics raycast.
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var params := PhysicsRayQueryParameters3D.create(
			_player_camera.global_position,
			global_position
		)
		# Exclude the player's own collider so it doesn't block the ray.
		params.exclude = [player_node.get_rid()]

		var hit: Dictionary = space.intersect_ray(params)
		if hit and hit.get("collider") == self:
			blackboard["is_being_looked_at"] = true
			return BaseNode.Status.SUCCESS

	blackboard["is_being_looked_at"] = false
	return BaseNode.Status.SUCCESS


## Hunt movement with Weeping Angel freeze.
## Pathfinds through the cognitive map to the player's position.
## Returns RUNNING to keep the hunt branch active every frame.
func _action_hunt_movement() -> int:
	if blackboard["is_being_looked_at"]:
		# Weeping Angel: completely stop while the player is watching.
		_current_speed = 0.0
		return BaseNode.Status.RUNNING

	# Player is not looking — move toward their current position.
	blackboard["last_known_player_position"] = player_node.global_position
	_current_speed = hunt_speed

	# Recompute path periodically (player moves).
	var now: float = Time.get_ticks_msec() / 1000.0
	if _current_path.is_empty() or _path_index >= _current_path.size() \
			or now - _path_compute_time > 0.5:
		_compute_path_to(player_node.global_position)

	return BaseNode.Status.RUNNING


## Check whether the AI has reached the player and trigger the catch event.
func _action_check_caught() -> int:
	if blackboard["distance_to_player"] <= catch_distance:
		trigger_player_caught.rpc()
	return BaseNode.Status.SUCCESS


# ── Conditions / Actions: Cross-Floor Pursuit Branch ─────────────────────────

## Gate: true while the AI is routing to / climbing the staircase.
## Auto-cancels when AI and player share the same floor.
func _condition_cross_floor_pursue() -> bool:
	if not blackboard["cross_floor_pursue"]:
		return false
	if blackboard["ai_floor"] == blackboard["player_floor"]:
		blackboard["cross_floor_pursue"] = false
		_clear_path()
		return false
	return true


## Pathfind to discovered stairs using the cognitive map.
## If no stairs have been discovered yet, explore aggressively toward frontiers.
func _action_cross_floor_pursue() -> int:
	_current_speed = hunt_speed
	var active_map := _get_active_map()

	if active_map.has_discovered_stairs():
		# Stairs are known — pathfind to the nearest stair entry.
		var stair_pos := active_map.get_nearest_stair_entry(
			global_position, global_position.y
		)
		if stair_pos != Vector3.ZERO:
			# Recompute path if we don't have one or the current one is stale.
			if _current_path.is_empty() or _path_index >= _current_path.size() \
					or _path_target.distance_to(stair_pos) > 2.0:
				_compute_path_to(stair_pos)

		# Check if we've reached the other floor.
		if blackboard["ai_floor"] == blackboard["player_floor"]:
			blackboard["cross_floor_pursue"] = false
			_clear_path()
			print("[RW] Cross-floor pursue complete — reached player's floor.")
			return BaseNode.Status.SUCCESS
	else:
		# No stairs discovered — explore aggressively toward frontiers.
		if _current_path.is_empty() or _path_index >= _current_path.size():
			_pick_explore_target()

	return BaseNode.Status.RUNNING


# ── Actions: Investigate Branch ───────────────────────────────────────────────

## Navigate toward the last heard sound using the cognitive map.
## Clears the sound target on arrival (within sound_reach_distance).
func _action_navigate_to_sound() -> int:
	var target: Vector3 = blackboard["last_heard_sound_position"]

	# Discard sounds that originated on a different floor — the AI has no way
	# to reach them and would just navigate into a wall or ceiling.
	if _get_floor(target.y) != blackboard["ai_floor"]:
		blackboard["has_sound_target"] = false
		_clear_path()
		return BaseNode.Status.FAILURE

	_current_speed = investigate_speed

	# Compute path if needed.
	if _current_path.is_empty() or _path_index >= _current_path.size() \
			or _path_target.distance_to(target) > 2.0:
		_compute_path_to(target)

	if global_position.distance_to(target) <= sound_reach_distance:
		# Arrived at the sound source — clear the target.
		blackboard["has_sound_target"] = false
		_clear_path()
		return BaseNode.Status.SUCCESS

	return BaseNode.Status.RUNNING


# ── Actions: Explore Branch ───────────────────────────────────────────────────

## Frontier-based exploration: navigate toward unmapped territory.
## The ExploreTimer triggers periodic retargeting.
func _action_random_exploration() -> int:
	_current_speed = explore_speed

	# Pick a new target if we've arrived or have no path.
	if _current_path.is_empty() or _path_index >= _current_path.size():
		_pick_explore_target()

	return BaseNode.Status.RUNNING


## Pick the next exploration target using the cognitive map's frontier system.
func _pick_explore_target() -> void:
	var active_map := _get_active_map()
	var current_time: float = Time.get_ticks_msec() / 1000.0

	# Try frontier first: nearest walkable cell adjacent to unknown territory.
	var frontier := active_map.get_nearest_frontier(global_position, current_time)
	if frontier != Vector3.ZERO:
		_compute_path_to(frontier)
		_explore_timer.wait_time = randf_range(4.0, 6.0)
		_explore_timer.start()
		return

	# Fully explored — pick a random walkable cell to patrol.
	var random_target := active_map.get_random_walkable(global_position)
	if random_target != Vector3.ZERO:
		_compute_path_to(random_target)
	else:
		# Map is essentially empty (just spawned). Move forward to start sensing.
		var forward := -global_transform.basis.z * 5.0
		_path_target = global_position + forward
		_current_path = PackedVector2Array([Vector2(_path_target.x, _path_target.z)])
		_path_index = 0

	_explore_timer.wait_time = randf_range(4.0, 6.0)
	_explore_timer.start()


# ── Path Computation ─────────────────────────────────────────────────────────

## Compute an A* path through the active cognitive map to a world position.
func _compute_path_to(target: Vector3) -> void:
	var active_map := _get_active_map()
	_current_path = active_map.find_path(global_position, target)
	_path_index = 0
	_path_target = target
	_path_compute_time = Time.get_ticks_msec() / 1000.0

	# If pathfinding failed (target in unexplored or unreachable territory),
	# find a frontier cell biased toward the target instead of walking into walls.
	if _current_path.is_empty():
		var current_time: float = _path_compute_time
		var frontier := active_map.get_frontier_toward(global_position, target, current_time)
		if frontier != Vector3.ZERO:
			_current_path = active_map.find_path(global_position, frontier)
			_path_index = 0
		# If still empty (no reachable frontier exists), AI stays put rather than
		# blindly walking toward the target into walls.


## Clear the cached path (used when switching behavior branches).
func _clear_path() -> void:
	_current_path = PackedVector2Array()
	_path_index = 0
	_path_target = Vector3.ZERO


# ── Movement ─────────────────────────────────────────────────────────────────

## Follow the cached cognitive map path.  Applies gravity and rotation.
func _apply_movement(delta: float) -> void:
	# Apply gravity when airborne.
	if not is_on_floor():
		velocity.y -= gravity_force * delta

	# Nothing to do if stopped or no path.
	if _current_speed <= 0.0:
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
		_stuck_timer = 0.0
		return

	# Follow the path.
	if _current_path.is_empty() or _path_index >= _current_path.size():
		# Path exhausted — decelerate.
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
		_stuck_timer = 0.0
		return

	# ── Stuck detection ─────────────────────────────────────────────────────
	# After move_and_slide(), the actual velocity reflects wall collisions.
	# If the AI's real XZ speed is near zero while it's trying to move,
	# it's stuck against a wall.
	var actual_xz_speed: float = Vector2(velocity.x, velocity.z).length()
	if actual_xz_speed < STUCK_VELOCITY_THRESHOLD and _current_speed > 0.0:
		_stuck_timer += delta
		if _stuck_timer >= STUCK_TIME_THRESHOLD:
			_stuck_timer = 0.0
			# Mark the next waypoint's cell as blocked (it's inside a wall).
			var active_map := _get_active_map()
			if _path_index < _current_path.size():
				var wp_stuck: Vector2 = _current_path[_path_index]
				active_map.mark_blocked(Vector3(wp_stuck.x, global_position.y, wp_stuck.y))
			# Recompute path around the obstacle.
			_compute_path_to(_path_target)
			return
	else:
		_stuck_timer = 0.0

	# Get the next waypoint (XZ coordinates from grid path).
	var wp: Vector2 = _current_path[_path_index]
	var flat_dir := Vector3(wp.x - global_position.x, 0.0, wp.y - global_position.z)
	var xz_dist: float = flat_dir.length()

	# Advance to next waypoint if close enough.
	if xz_dist < 1.0:
		_path_index += 1
		if _path_index >= _current_path.size():
			# Arrived at final waypoint.
			velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
			return
		wp = _current_path[_path_index]
		flat_dir = Vector3(wp.x - global_position.x, 0.0, wp.y - global_position.z)
		xz_dist = flat_dir.length()

	if xz_dist > 0.01:
		flat_dir = flat_dir / xz_dist  # normalize

	velocity.x = flat_dir.x * _current_speed
	velocity.z = flat_dir.z * _current_speed

	# Smoothly rotate the AI body to face its direction of travel.
	if flat_dir.length_squared() > 0.001:
		var target_angle: float = atan2(flat_dir.x, flat_dir.z)
		rotation.y = lerp_angle(rotation.y, target_angle, rotation_speed * delta)


# ── Multiplayer ───────────────────────────────────────────────────────────────

## Called when the AI catches the player. Broadcasts to all peers.
## "any_peer"   — the authority (this AI) initiates the call
## "call_local" — also executes on the calling machine
## "reliable"   — guaranteed delivery; appropriate for a game-ending event
@rpc("any_peer", "call_local", "reliable")
func trigger_player_caught() -> void:
	# Integration point: connect this to your game manager or death sequence.
	# Example: get_tree().call_group("game_manager", "on_player_caught")
	push_warning("[RitualWatcher] Player caught! Wire trigger_player_caught() to your game manager.")
