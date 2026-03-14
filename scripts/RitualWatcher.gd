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
##   3. PURSUE_LAST_KNOWN  — walk to the player's last seen position
##   4. EXPLORE            — roam to random navmesh points
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
## Toggle the Weeping Angel mechanic on/off for testing.
## When false the AI ignores whether the player is looking and always moves.
@export var weeping_angel_enabled: bool = true
## Distance at which the AI begins hunting the player (m).
@export var hunt_enter_distance: float = 50
## Hysteresis distance — AI stops hunting only when player moves beyond this (m).
@export var hunt_exit_distance: float  = 55
## Camera-to-AI dot product threshold that counts as "being looked at".
## 0.6 means the player must be facing within ~53° of the AI.
@export var look_dot_threshold: float  = 0.6
## Distance at which the player is caught (m).
@export var catch_distance: float      = 2.0
## Distance at which a sound investigation target is considered "reached" (m).
@export var sound_reach_distance: float = 3.0
## Maximum vertical distance (m) between the AI and the player before the AI
## ignores the player entirely.  Set this just below your floor-to-floor height
## so the AI never hunts a player standing on a different storey.
@export var same_floor_y_threshold: float = 2.5
## Maximum distance at which the AI can spot the player through its vision cone (m).
@export var ai_sight_distance: float = 20.0
## Dot product threshold for the AI's forward vision cone.
## 0.3 ≈ 72° half-angle (full ~144° cone).  0.5 ≈ 60°.
@export var ai_sight_dot_threshold: float = 0.3

@export_group("Movement")
## Speed while hunting the player (m/s).
@export var hunt_speed: float        = 5.5
## Speed while investigating a sound (m/s).
@export var investigate_speed: float = 3.0
## Speed while exploring randomly (m/s).
@export var explore_speed: float     = 2.0
## How quickly the AI rotates toward its movement direction (higher = snappier).
@export var rotation_speed: float    = 5.0
## Gravity force applied manually each frame (must match Jolt world gravity).
@export var gravity_force: float     = 20.0

@export_group("Animation")
## Crossfade duration (seconds) when transitioning between animations.
@export var anim_crossfade: float = 0.2

@export_group("Stuck Reset")
## Minimum metres the AI must travel per 1-second sample window to not be considered stuck.
## At explore_speed=2.0 m/s the AI covers ~2m in 1s, so 0.3m is a very conservative floor.
@export var stuck_min_move: float = 0.3
## Seconds of accumulated stuck time before the AI teleports back to its spawn position.
@export var stuck_timeout: float = 5.0


# ── Node References ────────────────────────────────────────────────────────────

@onready var _nav_agent:      NavigationAgent3D = $NavigationAgent3D
@onready var _behavior_tree:  BehaviorTree      = $BehaviorTree
@onready var _noise_detector: NoiseDetector     = $NoiseDetector
@onready var _explore_timer:  Timer             = $ExploreTimer
@onready var _anim_player:    AnimationPlayer   = $AnimationPlayer


# ── Blackboard ────────────────────────────────────────────────────────────────
##
## Shared data dictionary passed by reference to all action/condition callables.
## In GDScript 4, Dictionaries are reference types — closures capture the same
## underlying object, so every write here is immediately visible everywhere.

var blackboard: Dictionary = {
	"last_heard_sound_position":  Vector3.ZERO,
	"last_known_player_position": Vector3.ZERO,
	"distance_to_player":         INF,
	"is_being_looked_at":         false,
	"player_visible_to_ai":       false,
	"has_sound_target":           false,
	"has_last_known_target":      false,
	"is_hunting":                 false,
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

# ── Animation State ────────────────────────────────────────────────────────────

## Name of the animation currently playing on the AnimationPlayer.
var _current_anim: StringName = &""

# ── Stuck-Reset State ──────────────────────────────────────────────────────────

## World-space position where this instance spawned — the teleport destination.
var _spawn_position: Vector3    = Vector3.ZERO
## Position snapshot taken at the start of the current 1-second sample window.
var _stuck_sample_pos: Vector3  = Vector3.ZERO
## Elapsed time within the current sample window.
var _stuck_sample_elapsed: float = 0.0
## Seconds of accumulated stuck time while not hunting.
var _stuck_timer: float         = 0.0

# ── Debug ──────────────────────────────────────────────────────────────────────
## Accumulates delta; prints a status snapshot every DEBUG_INTERVAL seconds.
var _debug_timer: float = 0.0
const DEBUG_INTERVAL: float = 5.0


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

	# Configure AnimationPlayer to update during physics step so it stays in
	# sync with AI movement logic.
	_anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	_anim_player.play(&"Idle")
	_current_anim = &"Idle"

	# Record spawn position for stuck-reset teleport destination.
	_spawn_position       = global_position
	_stuck_sample_pos     = global_position
	_stuck_sample_elapsed = 0.0

	print("[RW] _ready() complete. NavigationAgent3D active, behaviour tree built.")


func _physics_process(delta: float) -> void:
	# Authority guard — never run AI logic on non-authority peers.
	if not is_multiplayer_authority():
		return

	_update_blackboard()                    # 1. refresh sensor values
	_noise_detector.check_noise(blackboard) # 2. poll the sound detector
	_update_ai_vision()                     # 3. update AI line-of-sight to player
	_action_update_look_detection()         # 4. always refresh look state before tree ticks
	_behavior_tree.tick()                   # 5. evaluate tree (sets speed, sets nav target)
	_apply_movement(delta)                  # 6. move toward next nav path position
	_update_animation()                     # 7. select and play the correct baked animation
	move_and_slide()                        # 8. apply velocity with Jolt physics
	_nav_agent.velocity = velocity          # 9. report actual velocity to nav agent
	_update_stuck_check(delta)              # 10. teleport to spawn if stuck while not hunting

	# ── Throttled debug snapshot ──────────────────────────────────────────────
	_debug_timer += delta
	if _debug_timer >= DEBUG_INTERVAL:
		_debug_timer = 0.0
		var _dbg_mode: String = (
			"HUNT"  if blackboard["is_hunting"] else
			"SOUND" if blackboard["has_sound_target"] else
			"LASTK" if blackboard["has_last_known_target"] else
			"ROAM"
		)
		print("[RW] %s | dist=%.1fm spd=%.1f | vis:%s frz:%s flr:%s | nav:%dwp" % [
			_dbg_mode,
			blackboard["distance_to_player"],
			_current_speed,
			"Y" if blackboard["player_visible_to_ai"] else "N",
			"Y" if blackboard["is_being_looked_at"] else "N",
			"Y" if is_on_floor() else "N",
			_nav_agent.get_current_navigation_path().size(),
		])


# ── Blackboard Sensor Update ──────────────────────────────────────────────────

func _update_blackboard() -> void:
	if not is_instance_valid(player_node):
		return
	blackboard["distance_to_player"] = global_position.distance_to(
		player_node.global_position
	)


## Updates blackboard["player_visible_to_ai"].
## The AI can see the player when:
##   1. Same floor (y difference within same_floor_y_threshold)
##   2. Within ai_sight_distance
##   3. Player is inside the AI's forward vision cone (ai_sight_dot_threshold)
##   4. Unobstructed line of sight (physics raycast hits the player)
func _update_ai_vision() -> void:
	if not is_instance_valid(player_node):
		blackboard["player_visible_to_ai"] = false
		return

	# Same-floor guard.
	if absf(player_node.global_position.y - global_position.y) > same_floor_y_threshold:
		blackboard["player_visible_to_ai"] = false
		return

	# Range guard.
	if blackboard["distance_to_player"] > ai_sight_distance:
		blackboard["player_visible_to_ai"] = false
		return

	# FOV check: player must be inside the AI's forward cone.
	var ai_forward: Vector3    = -global_transform.basis.z
	var dir_to_player: Vector3 = (player_node.global_position - global_position).normalized()
	if ai_forward.dot(dir_to_player) < ai_sight_dot_threshold:
		blackboard["player_visible_to_ai"] = false
		return

	# Line-of-sight raycast from AI torso to player.
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		global_position,
		player_node.global_position
	)
	params.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(params)
	blackboard["player_visible_to_ai"] = hit and hit.get("collider") == player_node


# ── Behaviour Tree Construction ───────────────────────────────────────────────

func _build_behavior_tree() -> void:

	# ── HUNT_PLAYER ───────────────────────────────────────────────────────────
	# Activates when the player is within hunt_enter_distance.
	# Weeping Angel: the AI freezes while the player's camera is facing it.
	# Look state is updated in _physics_process before the tree ticks, so it
	# is current for every branch — including investigate and explore.
	var hunt_seq := SequenceNode.new([
		ConditionNode.new(_condition_should_hunt),
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

	# ── PURSUE_LAST_KNOWN ─────────────────────────────────────────────────────
	# Activated when hunt mode ends. The AI moves to the player's last seen
	# position, then falls through to exploration on arrival.
	var last_known_seq := SequenceNode.new([
		ConditionNode.new(func() -> bool: return blackboard["has_last_known_target"]),
		ActionNode.new(_action_pursue_last_known),
	])

	# Root Selector tries branches in priority order:
	#   1. HUNT_PLAYER         — chase the player when close and on same floor
	#   2. INVESTIGATE_SOUND   — react to loud noise on the same floor
	#   3. PURSUE_LAST_KNOWN   — walk to the spot where the player last escaped
	#   4. EXPLORE             — roam idle
	var root := SelectorNode.new([hunt_seq, investigate_seq, last_known_seq, explore_seq])
	_behavior_tree.set_root(root)


# ── Conditions ────────────────────────────────────────────────────────────────

## Hysteresis gate: engage hunt at <=hunt_enter_distance, hold until >hunt_exit_distance.
## Also triggers hunt when the AI directly sees the player (vision cone + raycast),
## which immediately discards any active noise investigation.
## A floor guard runs first — the AI never hunts a player on a different storey.
func _condition_should_hunt() -> bool:
	var dist: float = blackboard["distance_to_player"]

	# Floor guard: stop hunting and record last known position if the player
	# is on a different floor.
	var y_diff: float = absf(player_node.global_position.y - global_position.y)
	if y_diff > same_floor_y_threshold:
		if blackboard["is_hunting"]:
			blackboard["is_hunting"] = false
			blackboard["last_known_player_position"] = player_node.global_position
			blackboard["has_last_known_target"] = true
			_clear_path()
		return false

	# Vision trigger: AI spots the player inside its FOV — start hunting and
	# discard any noise target so the chase takes immediate priority.
	if blackboard["player_visible_to_ai"] and not blackboard["is_hunting"]:
		blackboard["is_hunting"]       = true
		blackboard["has_sound_target"] = false
		_clear_path()
		return true

	if blackboard["is_hunting"]:
		# Currently hunting — keep hunting unless the player has escaped far enough.
		if dist > hunt_exit_distance:
			blackboard["is_hunting"] = false
			blackboard["last_known_player_position"] = player_node.global_position
			blackboard["has_last_known_target"] = true
			_clear_path()
			return false
		return true
	else:
		# Not currently hunting — begin only if player is close enough.
		if dist <= hunt_enter_distance:
			blackboard["is_hunting"]       = true
			blackboard["has_sound_target"] = false
			_clear_path()
			return true
		return false


# ── Actions: Hunt Branch ──────────────────────────────────────────────────────

## Weeping Angel logic.
## Checks whether the player's camera is directly facing the AI and whether
## an unobstructed line of sight exists. Updates blackboard["is_being_looked_at"].
## The freeze only activates within hunt_enter_distance metres — beyond
## that the player is too far away for the mechanic to feel intentional.
## Always returns SUCCESS — it is a sensor update, not a decision.
func _action_update_look_detection() -> int:
	# Distance guard: freeze only applies within the hunt engagement zone.
	if blackboard["distance_to_player"] > hunt_enter_distance:
		blackboard["is_being_looked_at"] = false
		return BaseNode.Status.SUCCESS

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
	if weeping_angel_enabled and blackboard["is_being_looked_at"]:
		# Weeping Angel: completely stop while the player is watching.
		_current_speed = 0.0
		return BaseNode.Status.RUNNING
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


# ── Actions: Pursue Last Known Branch ────────────────────────────────────────

## Navigate to the position where the player was last seen when hunt mode ended.
## Weeping Angel freeze still applies. Clears the target on arrival and falls
## through to exploration if the player has not re-entered hunt range.
func _action_pursue_last_known() -> int:
	# Weeping Angel: freeze while the player is watching.
	if weeping_angel_enabled and blackboard["is_being_looked_at"]:
		_current_speed = 0.0
		return BaseNode.Status.RUNNING

	var target: Vector3 = blackboard["last_known_player_position"]
	_current_speed = investigate_speed

	if _nav_agent.is_navigation_finished() or _can_recompute_path():
		_compute_path_to(target)

	if global_position.distance_to(target) <= sound_reach_distance:
		# Reached the last known position — give up and explore.
		blackboard["has_last_known_target"] = false
		_pick_explore_target()
		return BaseNode.Status.SUCCESS

	return BaseNode.Status.RUNNING


# ── Actions: Investigate Branch ───────────────────────────────────────────────

## Navigate toward the last heard sound using the navmesh.
## Clears the sound target on arrival (within sound_reach_distance).
func _action_navigate_to_sound() -> int:
	# Weeping Angel: freeze in place while the player is watching,
	# even during investigation so the effect applies to all movement.
	if weeping_angel_enabled and blackboard["is_being_looked_at"]:
		_current_speed = 0.0
		return BaseNode.Status.RUNNING

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
## Always restarts the timer so it is ready when the AI returns to explore.
## Does NOT set a nav target while a higher-priority behavior holds the path:
## the ExploreTimer fires unconditionally (including during hunt and freeze),
## so without this guard it would corrupt the nav target with a random point
## and reset PATH_COOLDOWN, causing the AI to chase walls for up to 0.5 s.
func _pick_explore_target() -> void:
	_explore_timer.wait_time = randf_range(4.0, 8.0)
	_explore_timer.start()
	if blackboard["is_hunting"] or blackboard["has_sound_target"] or blackboard["has_last_known_target"]:
		return
	var map_rid: RID = get_world_3d().navigation_map
	var target: Vector3 = NavigationServer3D.map_get_random_point(map_rid, 0xFFFF, false)
	if target != Vector3.ZERO:
		_compute_path_to(target)


## Detects when the AI has not moved for [stuck_timeout] seconds while not hunting
## and teleports it back to its original spawn position to break the stuck state.
##
## Uses a 1-second sample window rather than a per-frame comparison so the check
## is frame-rate independent and won't false-fire on normal movement speeds.
func _update_stuck_check(delta: float) -> void:
	if blackboard["is_hunting"]:
		# Reset everything so the clock only runs outside hunt mode.
		_stuck_timer          = 0.0
		_stuck_sample_elapsed = 0.0
		_stuck_sample_pos     = global_position
		return

	_stuck_sample_elapsed += delta

	# Evaluate every ~1 second how far the AI has actually moved.
	if _stuck_sample_elapsed >= 1.0:
		var moved: float = global_position.distance_to(_stuck_sample_pos)
		if moved < stuck_min_move:
			_stuck_timer += _stuck_sample_elapsed   # genuinely not moving
		else:
			_stuck_timer = 0.0                      # moved enough — reset

		_stuck_sample_elapsed = 0.0
		_stuck_sample_pos     = global_position

	# Teleport to spawn once stuck time exceeds the threshold,
	# then immediately pick a fresh random explore target so the AI does not
	# path back toward the same direction that caused the stuck state.
	if _stuck_timer >= stuck_timeout:
		_stuck_timer          = 0.0
		_stuck_sample_elapsed = 0.0
		_stuck_sample_pos     = _spawn_position
		global_position       = _spawn_position
		velocity              = Vector3.ZERO
		# Clear any stale nav target and cooldown so the next request fires immediately.
		_clear_path()
		# Also clear any lingering sound / last-known targets that may have been
		# pointing toward the problematic location.
		blackboard["has_sound_target"]      = false
		blackboard["has_last_known_target"] = false
		# Pick a brand new random explore point on the navmesh.
		_pick_explore_target()
		print("[RW] Stuck reset — teleported to spawn: ", _spawn_position)


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


# ── Animation ────────────────────────────────────────────────────────────────



## Selects and plays the correct baked animation on the AnimationPlayer.
## Chooses between "Sprint", "Walk", and "Idle" based on the current AI state.
func _update_animation() -> void:
	var desired: StringName

	var xz_speed: float = Vector2(velocity.x, velocity.z).length()
	var is_hunting: bool = blackboard["is_hunting"]

	if is_hunting and _current_speed > 0.5 and xz_speed > 0.5:
		desired = &"Sprint"
	elif xz_speed > 0.1:
		desired = &"Walk"
	else:
		desired = &"Idle"

	if desired != _current_anim:
		_current_anim = desired
		_anim_player.play(desired, anim_crossfade)


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
