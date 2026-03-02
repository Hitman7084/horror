class_name RitualWatcher
extends CharacterBody3D

# ── Floor IDs ─────────────────────────────────────────────────────────────────
## Numeric identifiers returned by _get_floor(). Stored in the blackboard so
## every branch can read them without recomputing per-frame.
const FLOOR_BASEMENT:   int = 0   # Y < basement_ceiling_y
const FLOOR_TRANSITION: int = 1   # on stairs (between the two thresholds)
const FLOOR_GROUND:     int = 2   # Y > ground_floor_y

## Hard-coded world position of the staircase basement entrance.
## Matches Basement/BoilerRoom/Stairs Stair25 (~bottom step).
const STAIR_BASE_POS := Vector3(-120.0, -7.3, -33.8)
## Hard-coded world position of the staircase upper landing.
## Matches Basement/BoilerRoom/Stairs Stair1 (~top step).
const STAIR_TOP_POS  := Vector3(-120.0, -2.5, -29.0)

## ── RitualWatcher AI Controller ───────────────────────────────────────────────
##
## Advanced horror AI using a Behaviour Tree architecture.
## Behaviours (priority order):
##   1. HUNT_PLAYER   — chase the player with Weeping Angel freeze mechanic
##   2. INVESTIGATE_SOUND — move toward the last heard loud noise
##   3. EXPLORE       — wander the basement randomly
##
## Required scene structure:
##   RitualWatcher (CharacterBody3D)   ← attach this script
##   ├── CollisionShape3D              (CapsuleShape3D, r=0.4, h=1.8)
##   ├── MeshInstance3D                (AI visual mesh)
##   ├── NavigationAgent3D
##   ├── BehaviorTree (Node)           ← attach BehaviorTree.gd
##   ├── NoiseDetector (Area3D)        ← attach NoiseDetector.gd
##   │   └── CollisionShape3D          (SphereShape3D, radius=70.0)
##   └── ExploreTimer (Timer)
##
## Inspector setup:
##   • player_node  → drag the Player (CharacterBody3D) from the scene
##   • Verify the player is in the "player" group (Project > Groups)
##   • A NavigationRegion3D with a baked NavMesh must exist in the scene


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
## Max height of a single stair step the AI can automatically step over.
@export var step_height: float       = 0.35

@export_group("Patrol")
## Node3D markers placed in the scene at corridor/room positions.
## The AI picks from these randomly during exploration.
## Place at least one per room and at each corridor entrance/exit.
@export var patrol_waypoints: Array[Node3D] = []
## When true the AI picks waypoints randomly; when false it loops sequentially.
@export var randomise_patrol: bool = true


# ── Node References ────────────────────────────────────────────────────────────

@onready var _nav_agent:      NavigationAgent3D = $NavigationAgent3D
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
	"stair_phase":                0,      # 0=heading to base  1=climbing to top
}


# ── Internal State ────────────────────────────────────────────────────────────

## Target speed applied this frame. Set by whichever branch is active.
var _current_speed: float = 0.0

## Current random exploration waypoint.
var _explore_target: Vector3 = Vector3.ZERO

## Index of the last waypoint used; advances each time a new target is picked.
var _current_waypoint_idx: int = 0

## Cooldown in seconds before another obstacle-avoidance redirect fires.
## Prevents the ray from triggering _pick_explore_target() every frame near a wall.
var _avoidance_cooldown: float = 0.0

## Cached Camera3D from the player scene. Set in _ready(), lazily refreshed.
var _player_camera: Camera3D = null

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

	# NavigationAgent3D — configure path tolerances.
	_nav_agent.path_desired_distance   = 0.5
	_nav_agent.target_desired_distance = 1.0
	_nav_agent.navigation_finished.connect(_on_navigation_finished)

	# Exploration timer — randomised wait time, restarted on each timeout.
	_explore_timer.one_shot  = false
	_explore_timer.autostart = false
	_explore_timer.timeout.connect(_pick_explore_target)
	_explore_timer.wait_time = randf_range(4.0, 6.0)
	_explore_timer.start()

	# Pick an initial exploration target immediately so the AI isn't frozen
	# on the first several frames while it waits for the timer.
	_pick_explore_target()

	# Build and activate the behaviour tree.
	_build_behavior_tree()
	print("[RW] _ready() complete. Behaviour tree built.")


func _physics_process(delta: float) -> void:
	# Authority guard — never run AI logic on non-authority peers.
	if not is_multiplayer_authority():
		return

	_update_blackboard()                    # 1. refresh sensor values
	_noise_detector.check_noise(blackboard) # 2. poll the sound detector
	_behavior_tree.tick()                   # 3. evaluate tree (sets speed + nav target)
	_apply_navigation_movement(delta)       # 4. translate nav path to velocity
	_handle_step_up()                       # 5. snap up stair steps before resolving
	move_and_slide()                        # 6. apply velocity with Jolt physics

	# ── Throttled debug snapshot ──────────────────────────────────────────────
	_debug_timer += delta
	if _debug_timer >= DEBUG_INTERVAL:
		_debug_timer = 0.0
		print("────────── [RitualWatcher] DEBUG ──────────")
		print("  dist_to_player : ", snappedf(blackboard["distance_to_player"], 0.1))
		print("  is_hunting     : ", blackboard["is_hunting"])
		print("  is_looked_at   : ", blackboard["is_being_looked_at"])
		print("  has_sound_tgt  : ", blackboard["has_sound_target"])
		print("  current_speed  : ", _current_speed)
		print("  velocity       : ", velocity.snappedf(0.01))
		print("  explore_target : ", _explore_target.snappedf(0.1))
		print("  nav finished   : ", _nav_agent.is_navigation_finished())
		print("  nav next pos   : ", _nav_agent.get_next_path_position().snappedf(0.1))
		print("  on_floor       : ", is_on_floor())
		print("  ai_floor       : ", blackboard["ai_floor"],
			"  (0=basement 1=stairs 2=ground)")
		print("  player_floor   : ", blackboard["player_floor"],
			"  (0=basement 1=stairs 2=ground)")
		print("  cross_floor    : ", blackboard["cross_floor_pursue"],
			"  stair_phase: ", blackboard["stair_phase"])
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
			blackboard["stair_phase"] = 0
			print("[RW] Cross-floor pursue triggered (noise=", noise, ")")


## Returns the floor ID constant for a given world Y position.
func _get_floor(y: float) -> int:
	if y < basement_ceiling_y:
		return FLOOR_BASEMENT
	elif y > ground_floor_y:
		return FLOOR_GROUND
	else:
		return FLOOR_TRANSITION


# ── Behaviour Tree Construction ───────────────────────────────────────────────

func _build_behavior_tree() -> void:

	# ── HUNT_PLAYER ───────────────────────────────────────────────────────────
	# Activates when the player is within hunt_enter_distance.
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
	# AI navigates to the stair base, then climbs to the transition zone.
	var cross_floor_seq := SequenceNode.new([
		ConditionNode.new(_condition_cross_floor_pursue),
		ActionNode.new(_action_cross_floor_pursue),
	])

	# ── EXPLORE ───────────────────────────────────────────────────────────────
	# Fallback: wander randomly when there is nothing else to do.
	var explore_seq := SequenceNode.new([
		ActionNode.new(_action_random_exploration),
	])

	# Root Selector tries branches in priority order.
	var root := SelectorNode.new([hunt_seq, cross_floor_seq, investigate_seq, explore_seq])
	_behavior_tree.set_root(root)


# ── Conditions ────────────────────────────────────────────────────────────────

## Hysteresis gate: engage hunt at <=50 m, hold it until >55 m.
## Prevents the AI from rapidly toggling in/out of hunt at the boundary.
func _condition_should_hunt() -> bool:
	# Never hunt across floors — AI cannot see or reach the player through ceilings.
	if blackboard["ai_floor"] != blackboard["player_floor"]:
		if blackboard["is_hunting"]:
			blackboard["is_hunting"] = false
			_pick_explore_target()
		return false

	var dist: float = blackboard["distance_to_player"]

	if blackboard["is_hunting"]:
		# Currently hunting — keep hunting unless the player has escaped far enough.
		if dist > hunt_exit_distance:
			blackboard["is_hunting"] = false
			# Pick a fresh random waypoint immediately so the AI doesn't
			# continue drifting in the last hunt direction.
			_pick_explore_target()
			return false
		return true
	else:
		# Not currently hunting — begin only if player is close enough.
		if dist <= hunt_enter_distance:
			blackboard["is_hunting"] = true
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
## Returns RUNNING to keep the hunt branch active every frame.
func _action_hunt_movement() -> int:
	if blackboard["is_being_looked_at"]:
		# Weeping Angel: completely stop while the player is watching.
		_current_speed = 0.0
		return BaseNode.Status.RUNNING

	# Player is not looking — move toward their current position.
	blackboard["last_known_player_position"] = player_node.global_position
	_current_speed = hunt_speed
	_nav_agent.target_position = blackboard["last_known_player_position"]
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
		blackboard["stair_phase"] = 0
		return false
	return true


## Two-phase stair climb.
## Phase 0: navigate to STAIR_BASE_POS (basement entrance of stairs).
## Phase 1: navigate to STAIR_TOP_POS (upper landing) until floor zone changes.
func _action_cross_floor_pursue() -> int:
	if blackboard["stair_phase"] == 0:
		_current_speed = hunt_speed
		_nav_agent.target_position = STAIR_BASE_POS
		if global_position.distance_to(STAIR_BASE_POS) <= sound_reach_distance:
			blackboard["stair_phase"] = 1
			print("[RW] Stair base reached, climbing.")
		return BaseNode.Status.RUNNING

	_current_speed = hunt_speed
	_nav_agent.target_position = STAIR_TOP_POS
	if blackboard["ai_floor"] >= FLOOR_TRANSITION:
		blackboard["cross_floor_pursue"] = false
		blackboard["stair_phase"] = 0
		print("[RW] Reached transition floor — cross-floor pursue complete.")
		return BaseNode.Status.SUCCESS
	return BaseNode.Status.RUNNING


# ── Actions: Investigate Branch ───────────────────────────────────────────────

## Navigate toward the last heard sound.
## Clears the sound target on arrival (within sound_reach_distance).
func _action_navigate_to_sound() -> int:
	var target: Vector3 = blackboard["last_heard_sound_position"]

	# Discard sounds that originated on a different floor — the AI has no way
	# to reach them and would just navigate into a wall or ceiling.
	if _get_floor(target.y) != blackboard["ai_floor"]:
		blackboard["has_sound_target"] = false
		return BaseNode.Status.FAILURE

	_current_speed = investigate_speed
	_nav_agent.target_position = target

	if global_position.distance_to(target) <= sound_reach_distance:
		# Arrived at the sound source — clear the target.
		blackboard["has_sound_target"] = false
		return BaseNode.Status.SUCCESS

	return BaseNode.Status.RUNNING


# ── Actions: Explore Branch ───────────────────────────────────────────────────

## Idle exploration: navigate toward the current random waypoint.
## The ExploreTimer handles picking a new waypoint every 4–6 seconds.
func _action_random_exploration() -> int:
	_current_speed = explore_speed
	_nav_agent.target_position = _explore_target
	return BaseNode.Status.RUNNING


## Pick the next exploration target.
## Uses manual patrol_waypoints first; falls back to navmesh or random offset.
func _pick_explore_target() -> void:

	# ── Waypoint patrol (primary) ─────────────────────────────────────────────
	if patrol_waypoints.size() > 0:
		# Filter out any waypoints that may have been freed since assignment.
		var valid: Array = patrol_waypoints.filter(
			func(wp: Node3D) -> bool: return is_instance_valid(wp)
		)
		if valid.size() > 0:
			if randomise_patrol:
				_current_waypoint_idx = randi() % valid.size()
			else:
				_current_waypoint_idx = (_current_waypoint_idx + 1) % valid.size()
			_explore_target = valid[_current_waypoint_idx].global_position
			print("[RW] Waypoint [", _current_waypoint_idx, "] → ",
				_explore_target.snappedf(0.1))
			_explore_timer.wait_time = randf_range(4.0, 6.0)
			_explore_timer.start()
			return

	# ── NavMesh fallback (used when no waypoints are assigned) ────────────────
	var map: RID = _nav_agent.get_navigation_map()
	var new_target := Vector3.ZERO

	if map.is_valid():
		var random_point: Vector3 = NavigationServer3D.map_get_random_point(
			map, _nav_agent.navigation_layers, true
		)
		if random_point != Vector3.ZERO:
			new_target = random_point
		else:
			print("[RW] WARNING: map_get_random_point returned zero.",
				" Assign patrol_waypoints for reliable exploration.")
	else:
		print("[RW] WARNING: NavigationMap RID invalid.",
			" Assign patrol_waypoints for reliable exploration.")

	# ── Random offset fallback (last resort) ──────────────────────────────────
	if new_target == Vector3.ZERO:
		new_target = global_position + Vector3(
			randf_range(-15.0, 15.0),
			0.0,
			randf_range(-15.0, 15.0)
		)

	_explore_target = new_target
	print("[RW] Fallback explore target: ", _explore_target.snappedf(0.1))
	_explore_timer.wait_time = randf_range(4.0, 6.0)
	_explore_timer.start()


# ── Navigation Movement ───────────────────────────────────────────────────────

## Translate the NavigationAgent3D path into CharacterBody3D velocity.
## Applies manual gravity (required by Jolt Physics — it does not auto-apply).
## Falls back to direct movement when the navmesh cannot provide a path.
func _apply_navigation_movement(delta: float) -> void:
	# Apply gravity when airborne.
	if not is_on_floor():
		velocity.y -= gravity_force * delta

	# Decrement obstacle-avoidance cooldown every physics frame.
	if _avoidance_cooldown > 0.0:
		_avoidance_cooldown -= delta

	if _current_speed <= 0.0 or _nav_agent.is_navigation_finished():
		# Decelerate smoothly to zero when stopped or at destination.
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
		return

	var next_pos: Vector3 = _nav_agent.get_next_path_position()

	# Flatten to the horizontal plane — vertical movement handled by gravity.
	var flat_dir := Vector3(
		next_pos.x - global_position.x,
		0.0,
		next_pos.z - global_position.z
	)

	# When the NavigationAgent can't compute a path (AI not on navmesh, or navmesh
	# doesn't cover this area), get_next_path_position() returns the AI's own
	# position → flat_dir is zero. Fall back to direct movement toward the target.
	if flat_dir.length_squared() < 0.01:
		var target: Vector3 = _nav_agent.target_position
		flat_dir = Vector3(
			target.x - global_position.x,
			0.0,
			target.z - global_position.z
		)
		# If already at the target too, nothing to do this frame.
		if flat_dir.length_squared() < 0.01:
			velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
			return

	flat_dir = flat_dir.normalized()

	# ── Obstacle avoidance (explore mode only) ────────────────────────────────
	# Cast a 3 m ray in the movement direction. When a non-player obstacle is
	# detected and the cooldown has expired, reflect off the surface normal and
	# pick a fresh waypoint so the AI doesn't funnel into the same wall again.
	if not blackboard["is_hunting"] and not blackboard["has_sound_target"] \
			and _avoidance_cooldown <= 0.0:

		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var ray_params := PhysicsRayQueryParameters3D.create(
			global_position,
			global_position + flat_dir * 3.0
		)
		# Exclude the AI itself and the player — only geometry triggers avoidance.
		ray_params.exclude = [get_rid()]
		if is_instance_valid(player_node):
			ray_params.exclude.append(player_node.get_rid())

		var hit: Dictionary = space.intersect_ray(ray_params)
		if hit:
			# Flatten the surface normal to the horizontal plane.
			var wall_normal := Vector3(hit["normal"].x, 0.0, hit["normal"].z)
			if wall_normal.length_squared() > 0.001:
				flat_dir = flat_dir.reflect(wall_normal.normalized()).normalized()
			else:
				# Perfectly vertical wall — just reverse direction.
				flat_dir = -flat_dir
			# Cooldown prevents this branch firing for every frame near the wall.
			_avoidance_cooldown = 2.0
			# Pick a new waypoint in case the reflected path still leads into a wall.
			_pick_explore_target()

	velocity.x = flat_dir.x * _current_speed
	velocity.z = flat_dir.z * _current_speed

	# Smoothly rotate the AI body to face its direction of travel.
	var target_angle: float = atan2(flat_dir.x, flat_dir.z)
	rotation.y = lerp_angle(rotation.y, target_angle, rotation_speed * delta)


func _on_navigation_finished() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


## Automatically steps the AI up onto low obstacles (stair steps).
## Uses test_move() against the AI's own collision shape:
##   • blocked at current height AND clear when raised → it's a step → snap up.
##   • still blocked when raised           → it's a wall → let avoidance handle it.
func _handle_step_up() -> void:
	if not is_on_floor():
		return
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)
	if h_vel.length_squared() < 0.25:   # don't trigger while nearly stationary
		return
	var probe := h_vel.normalized() * 0.5   # 0.5 m forward probe
	if not test_move(global_transform, probe):
		return   # path is clear
	var lifted := global_transform
	lifted.origin.y += step_height
	if test_move(lifted, probe):
		return   # still blocked above — it's a wall, not a step
	global_position.y += step_height


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
