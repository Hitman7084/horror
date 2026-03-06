class_name RitualWatcher
extends CharacterBody3D

## ── RitualWatcher AI Controller ───────────────────────────────────────────────
##
## Horror AI using a Behaviour Tree architecture backed by the baked
## NavigationMesh3D.  NavigationAgent3D handles all pathfinding and obstacle
## avoidance through the baked navmesh.
##
## Behaviours (priority order):
##   1. HUNT_PLAYER        — chase the player with Weeping Angel freeze mechanic
##   2. INVESTIGATE_SOUND  — move toward the last heard loud noise
##   3. EXPLORE            — roam to random navmesh points
##
## Required scene structure:
##   RitualWatcher (CharacterBody3D)   <- attach this script
##   ├── CollisionShape3D              (CapsuleShape3D, r=0.3, h=1.8)
##   ├── MeshInstance3D                (AI visual mesh)
##   ├── NavigationAgent3D             <- pathfinding agent
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
@export var hunt_enter_distance: float = 50.0
## Hysteresis distance — AI stops hunting only when player moves beyond this (m).
@export var hunt_exit_distance: float  = 55.0
## Camera-to-AI dot product threshold that counts as "being looked at".
## 0.6 means the player must be facing within ~53° of the AI.
@export var look_dot_threshold: float  = 0.6
## Distance at which the player is caught (m).
@export var catch_distance: float      = 2.0
## Distance at which a sound investigation target is considered "reached" (m).
@export var sound_reach_distance: float = 3.0

@export_group("Movement")
## Speed while hunting the player (m/s).
@export var hunt_speed: float        = 3.5
## Speed while investigating a sound (m/s).
@export var investigate_speed: float = 3.0
## Speed while exploring randomly (m/s).
@export var explore_speed: float     = 2.0
## How quickly the AI rotates toward its movement direction (higher = snappier).
@export var rotation_speed: float    = 5.0
## Gravity force applied manually each frame (must match Jolt world gravity).
@export var gravity_force: float     = 20.0


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
	"last_heard_sound_position": Vector3.ZERO,
	"distance_to_player":        INF,
	"is_being_looked_at":        false,
	"has_sound_target":          false,
	"is_hunting":                false,
}


# ── Internal State ────────────────────────────────────────────────────────────

## Target speed applied this frame. Set by whichever branch is active.
var _current_speed: float = 0.0

## Cached Camera3D from the player scene. Set in _ready(), lazily refreshed.
var _player_camera: Camera3D = null

## Game-time (seconds) when we last issued a path request to the NavigationAgent3D.
## Prevents path thrashing: resetting target_position every frame discards
## the previous path before NavigationServer3D has a chance to compute it.
var _last_path_time: float = -1.0
## Minimum seconds between NavigationAgent3D path requests.
const PATH_COOLDOWN: float = 0.5

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

	# Configure NavigationAgent3D.
	# path_desired_distance must be large enough to account for Y offset
	# between the AI's CharacterBody3D and the navmesh surface.  The navmesh
	# sits at Y = -4.55 while the AI spawns at Y ~= -3.6 (a gap of ~0.95 m).
	# A value of 0.5 would be smaller than this gap, causing the agent to
	# never advance past the first waypoint.  2.0 gives comfortable margin.
	# target_desired_distance is smaller (1.0) so the AI actually reaches
	# the destination floor rather than stopping 2 m away vertically.
	_nav_agent.path_desired_distance   = 2.0
	_nav_agent.target_desired_distance = 1.0
	_nav_agent.avoidance_enabled       = false

	# Exploration timer — triggers a new random explore target periodically.
	_explore_timer.one_shot  = false
	_explore_timer.autostart = false
	_explore_timer.timeout.connect(_pick_explore_target)
	_explore_timer.wait_time = randf_range(4.0, 6.0)
	_explore_timer.start()

	# Build and activate the behaviour tree.
	_build_behavior_tree()
	print("[RW] _ready() complete. NavigationAgent3D active, behaviour tree built.")


func _physics_process(delta: float) -> void:
	# Authority guard — never run AI logic on non-authority peers.
	if not is_multiplayer_authority():
		return

	_update_blackboard()                    # 1. refresh sensor values
	_noise_detector.check_noise(blackboard) # 2. poll the sound detector
	_behavior_tree.tick()                   # 3. evaluate tree (sets speed, sets nav target)
	_apply_movement(delta)                  # 4. move toward next nav path position
	move_and_slide()                        # 5. apply velocity with Jolt physics
	_nav_agent.velocity = velocity          # 6. report actual velocity to nav agent

	# ── Throttled debug snapshot ──────────────────────────────────────────────
	_debug_timer += delta
	if _debug_timer >= DEBUG_INTERVAL:
		_debug_timer = 0.0
		print("────────── [RitualWatcher] DEBUG ──────────")
		print("  ai_position    : ", global_position.snapped(Vector3.ONE * 0.01))
		print("  dist_to_player : ", snappedf(blackboard["distance_to_player"], 0.1))
		print("  is_hunting     : ", blackboard["is_hunting"])
		print("  is_looked_at   : ", blackboard["is_being_looked_at"])
		print("  has_sound_tgt  : ", blackboard["has_sound_target"])
		print("  current_speed  : ", _current_speed)
		print("  velocity       : ", velocity.snapped(Vector3.ONE * 0.01))
		print("  on_floor       : ", is_on_floor())
		print("  nav_finished   : ", _nav_agent.is_navigation_finished())
		var _dbg_path := _nav_agent.get_current_navigation_path()
		print("  path_size      : ", _dbg_path.size())
		if _dbg_path.size() > 0:
			print("  next_path_pos  : ", _nav_agent.get_next_path_position().snapped(Vector3.ONE * 0.01))
		print("───────────────────────────────────────────")


# ── Blackboard Sensor Update ──────────────────────────────────────────────────

func _update_blackboard() -> void:
	if not is_instance_valid(player_node):
		return
	blackboard["distance_to_player"] = global_position.distance_to(
		player_node.global_position
	)


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

	# ── EXPLORE ───────────────────────────────────────────────────────────────
	# Fallback: roam to random points on the baked navmesh.
	var explore_seq := SequenceNode.new([
		ActionNode.new(_action_random_exploration),
	])

	# Root Selector tries branches in priority order.
	# INVESTIGATE_SOUND fires before HUNT so the AI goes to a noise position
	# rather than directly chasing the player when both conditions are active.
	var root := SelectorNode.new([investigate_seq, hunt_seq, explore_seq])
	_behavior_tree.set_root(root)


# ── Conditions ────────────────────────────────────────────────────────────────

## Hysteresis gate: engage hunt at <=hunt_enter_distance, hold until >hunt_exit_distance.
## Prevents the AI from rapidly toggling in/out of hunt at the boundary.
func _condition_should_hunt() -> bool:
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
## Pathfinds through the navmesh to the player's position.
## Returns RUNNING to keep the hunt branch active every frame.
func _action_hunt_movement() -> int:
	if blackboard["is_being_looked_at"]:
		# Weeping Angel: completely stop while the player is watching.
		_current_speed = 0.0
		return BaseNode.Status.RUNNING

	# Player is not looking — move toward their current position.
	_current_speed = hunt_speed

	# Recompute path when finished or after the cooldown (player keeps moving).
	if _nav_agent.is_navigation_finished() or _can_recompute_path():
		_compute_path_to(player_node.global_position)

	return BaseNode.Status.RUNNING


## Check whether the AI has reached the player and trigger the catch event.
func _action_check_caught() -> int:
	if blackboard["distance_to_player"] <= catch_distance:
		trigger_player_caught.rpc()
	return BaseNode.Status.SUCCESS


# ── Actions: Investigate Branch ───────────────────────────────────────────────

## Navigate toward the last heard sound using the navmesh.
## Clears the sound target on arrival (within sound_reach_distance).
func _action_navigate_to_sound() -> int:
	var target: Vector3 = blackboard["last_heard_sound_position"]

	_current_speed = investigate_speed

	# Set nav target if stale or finished.
	if _nav_agent.is_navigation_finished() or _can_recompute_path():
		_compute_path_to(target)

	if global_position.distance_to(target) <= sound_reach_distance:
		# Arrived at the sound source — clear the target and resume roaming.
		blackboard["has_sound_target"] = false
		_pick_explore_target()
		return BaseNode.Status.SUCCESS

	return BaseNode.Status.RUNNING


# ── Actions: Explore Branch ───────────────────────────────────────────────────

## Roam to random positions on the baked navmesh.
## The ExploreTimer triggers periodic retargeting.
func _action_random_exploration() -> int:
	_current_speed = explore_speed

	# Pick a new target when navigation finishes or no target is set.
	if _nav_agent.is_navigation_finished():
		_pick_explore_target()

	return BaseNode.Status.RUNNING


## Pick a random point on the baked navmesh as the next exploration target.
func _pick_explore_target() -> void:
	var map_rid: RID = get_world_3d().navigation_map
	var target: Vector3 = NavigationServer3D.map_get_random_point(map_rid, 0xFFFF, false)
	if target != Vector3.ZERO:
		_compute_path_to(target)
	_explore_timer.wait_time = randf_range(4.0, 8.0)
	_explore_timer.start()


# ── Path Computation ─────────────────────────────────────────────────────────

## Tell the NavigationAgent3D to path to a world position.
## Records the request time to enforce PATH_COOLDOWN between requests.
func _compute_path_to(target: Vector3) -> void:
	_nav_agent.target_position = target
	_last_path_time = Time.get_ticks_msec() / 1000.0


## Returns true when enough time has passed since the last path request.
## Prevents path thrashing caused by updating target_position every frame.
func _can_recompute_path() -> bool:
	return (Time.get_ticks_msec() / 1000.0) - _last_path_time >= PATH_COOLDOWN


## Reset the navigation target to halt movement.
## Also resets the cooldown so the very next path request fires immediately.
func _clear_path() -> void:
	_nav_agent.target_position = global_position
	_last_path_time = -1.0


# ── Movement ─────────────────────────────────────────────────────────────────

## Follow the NavigationAgent3D path. Applies gravity and rotation.
func _apply_movement(delta: float) -> void:
	# Apply gravity when airborne.
	if not is_on_floor():
		velocity.y -= gravity_force * delta

	# Decelerate when stopped or navigation is complete.
	if _current_speed <= 0.0 or _nav_agent.is_navigation_finished():
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
		return

	# Get the next position on the navmesh path.
	var next_pos: Vector3 = _nav_agent.get_next_path_position()
	var flat_dir := Vector3(
		next_pos.x - global_position.x,
		0.0,
		next_pos.z - global_position.z
	)
	var xz_dist: float = flat_dir.length()
	if xz_dist < 0.01:
		# At the next waypoint in XZ — coast to a stop and let the agent advance.
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
		return
	flat_dir /= xz_dist

	velocity.x = flat_dir.x * _current_speed
	velocity.z = flat_dir.z * _current_speed

	# Smoothly rotate the AI body to face its direction of travel.
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
