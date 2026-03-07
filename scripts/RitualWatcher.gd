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
@export var hunt_enter_distance: float = 10
## Hysteresis distance — AI stops hunting only when player moves beyond this (m).
@export var hunt_exit_distance: float  = 15
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

@export_group("Look Behavior")
## Radius within which the player triggers the neck/body look-at sequence (m).
## Separate from hunt_enter_distance — the AI notices the player before hunting.
@export var look_detect_radius: float  = 15.0
## Seconds the AI waits after the player enters look_detect_radius before the
## neck begins moving (the "slow realization" beat).
@export var neck_track_delay: float    = 1.0
## Seconds after the neck starts tracking before the body also begins rotating.
@export var body_track_delay: float    = 1.0
## Slerp speed factor for neck yaw each physics frame (higher = snappier turn).
@export var neck_rotation_speed: float = 3.0
## Lerp speed for body look-at rotation. Keep below rotation_speed so movement
## direction dominates during navigation.
@export var body_look_speed: float     = 2.0
## Half-angle clamp for neck yaw in degrees — prevents unnatural neck poses.
@export var neck_yaw_clamp_deg: float  = 60.0

@export_group("Walk Animation")
@export var walk_cycle_speed: float        = 2.5
@export var walk_leg_swing_amp: float      = 0.45
@export var walk_knee_bend_amp: float      = 0.4
@export var walk_arm_swing_amp: float      = 0.35
@export var walk_elbow_bend_amp: float     = 0.25
@export var walk_hip_sway_amp: float       = 0.08
@export var walk_blend_in_speed: float     = 5.0
@export var walk_blend_out_speed: float    = 4.0
@export var walk_shoulder_amp: float       = 0.06
@export var walk_toe_amp: float            = 0.15
@export var walk_spine1_amp: float         = 0.04
@export var walk_spine2_amp: float         = 0.03
@export var walk_hip_bob_amp: float        = 0.03
@export var walk_finger_curl_amp: float    = 0.1
## Asymmetry offset in radians added to right leg phase for horror limp.
@export var walk_asymmetry: float          = 0.15
## Left arm swings this factor wider than right (1.0 = symmetric).
@export var walk_left_arm_factor: float    = 1.2

@export_group("Idle Animation")
@export var idle_breath_speed: float        = 1.2
@export var idle_breath_spine_amp: float    = 0.02
@export var idle_breath_shoulder_amp: float = 0.015
@export var idle_finger_twitch_chance: float = 0.02
@export var idle_weight_shift_speed: float  = 0.3
@export var idle_weight_shift_amp: float    = 0.025

@export_group("Ambient Animation")
@export var ambient_min_interval: float  = 5.0
@export var ambient_max_interval: float  = 15.0
@export var ambient_anim_duration: float = 2.0

@export_group("Lunge Animation")
@export var lunge_duration: float        = 0.6
@export var lunge_arm_extend_amp: float  = 1.2
@export var lunge_spine_lean_amp: float  = 0.3
@export var lunge_finger_spread: float   = 0.4

@export_group("Run Animation")
## Leg swing amplitude while hunting (larger than walk for aggressive stride).
@export var run_leg_swing_amp: float    = 0.72
## Knee lift amplitude while hunting.
@export var run_knee_bend_amp: float    = 0.65
## Arm swing amplitude while hunting.
@export var run_arm_swing_amp: float    = 0.58
## Elbow bend amplitude while hunting.
@export var run_elbow_bend_amp: float   = 0.42
## Hip sway amplitude while hunting.
@export var run_hip_sway_amp: float     = 0.13
## Hip vertical bob amplitude while hunting.
@export var run_hip_bob_amp: float      = 0.06
## Forward spine lean in radians at full run blend.
@export var run_spine_lean: float       = 0.14
## Speed at which the blend transitions between walk and run poses (higher = snappier).
@export var run_blend_speed: float      = 4.0

@export_group("Footfall")
## Magnitude of the hip/spine compression on each foot plant.
@export var footfall_impact_amp: float  = 0.07
## Decay rate of the impact impulse per second (higher = shorter thud).
@export var footfall_decay_rate: float  = 10.0

@export_group("Posture")
## Radians to rotate upper arms down from the T-pose (arm adduction).
## Positive for left arm; mirrored negative applied to right arm automatically.
@export var arm_adduction_angle: float    = 0.35
## Radians to bring shoulder sockets forward (protraction).
@export var shoulder_protract_angle: float = 0.12
## Radians of natural resting elbow bend applied to both forearms.
@export var elbow_rest_bend: float        = 0.10

@export_group("Explore Behavior")
## ±Degrees of random head yaw during exploration scan.
@export var explore_head_scan_range_deg: float    = 65.0
## Lerp speed toward each new scan target (higher = snappier head snap).
@export var explore_head_scan_speed: float        = 1.2
## Minimum seconds between random head scan target picks.
@export var explore_head_scan_min_interval: float = 0.6
## Maximum seconds between random head scan target picks.
@export var explore_head_scan_max_interval: float = 2.8

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
@onready var _skeleton:       Skeleton3D        = $Skeleton3D


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


# ── Look-At State ─────────────────────────────────────────────────────────────

enum LookState {
	IDLE,           ## Player is outside look_detect_radius — neck at rest
	DELAY_NECK,     ## Player entered radius; counting down neck_track_delay
	TRACKING_NECK,  ## Neck rotating toward player; counting down body_track_delay
	TRACKING_FULL,  ## Neck AND body both rotating toward the player
	RETURNING,      ## Player exited radius; neck yaw blending back to 0
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

# ── Look-At Runtime State ─────────────────────────────────────────────────────

## Current stage of the neck/body look-at sequence.
var _look_state: LookState          = LookState.IDLE
## General-purpose timer for delays within the look state machine (seconds).
var _look_state_timer: float        = 0.0
## Resolved index of mixamorig_Neck_05. Set in _ready(); -1 = unresolved.
var _neck_bone_idx: int             = -1
## T-pose rest rotation of the neck bone, cached once in _ready().
var _neck_rest_rotation: Quaternion = Quaternion.IDENTITY
## Yaw (radians) currently applied to the neck bone this frame.
var _neck_current_yaw: float        = 0.0
## Desired yaw (radians) toward the player; 0 when not tracking.
var _neck_target_yaw: float         = 0.0
## True while TRACKING_FULL is active — read by _apply_movement().
var _body_look_active: bool         = false
## World-space yaw angle toward the player for body rotation, updated in TRACKING_FULL.
var _body_look_target_angle: float  = 0.0

## Neck yaw applied during explore scanning (IDLE look state only).
var _explore_head_yaw: float        = 0.0
## Current target yaw for the explore scan.
var _explore_head_target_yaw: float = 0.0
## Seconds since the last explore scan target was picked.
var _explore_head_scan_timer: float = 0.0
## Seconds until the next explore scan target pick.  Randomised on first tick.
var _explore_head_scan_next: float  = 0.0

# ── Bone Animation System ─────────────────────────────────────────────────────

## Bone index lookup: bone_name (String) → index (int).
var _bone_idx: Dictionary = {}
## Precomputed bone-local axis vectors for world-space sagittal (forward/back) swing.
var _bone_sagittal_axis: Dictionary = {}
## Precomputed bone-local axis vectors for world-space lateral (side-to-side) swing.
var _bone_lateral_axis: Dictionary = {}
## Precomputed bone-local axis vectors for world-space vertical (up/down) rotation.
var _bone_vertical_axis: Dictionary = {}
## T-pose rest rotation per bone index.
var _bone_rest_quat: Dictionary = {}

## Per-layer offset dictionaries: bone_idx (int) → Quaternion.
var _walk_offsets: Dictionary = {}
var _idle_offsets: Dictionary = {}
var _ambient_offsets: Dictionary = {}
var _lunge_offsets: Dictionary = {}
## Constant rest-pose correction applied independent of animation blend weight.
## Populated once in _ready() via _build_posture_offsets().
var _posture_offsets: Dictionary = {}

## Walk animation phase and blend weight.
var _walk_cycle: float       = 0.0
var _walk_anim_weight: float = 0.0
## Blend weight: 0 = walk parameters, 1 = run parameters. Driven by hunt state.
var _run_blend_weight: float = 0.0

## Footfall impact impulses. Set to 1.0 on foot plant, decay to 0.
var _impact_left: float  = 0.0
var _impact_right: float = 0.0
## Previous leg phase values used to detect foot-plant zero-crossings.
var _prev_left_phase: float  = 0.0
var _prev_right_phase: float = 0.0

## Idle animation time accumulator.
var _idle_time: float = 0.0
## Finger currently twitching (-1 = none).
var _idle_finger_twitch_bone: int = -1
## Progress 0→1 of the current finger twitch.
var _idle_finger_twitch_progress: float = 0.0

## Ambient animation state.
var _ambient_timer: float       = 0.0
var _ambient_next_trigger: float = 8.0
var _ambient_active: bool       = false
## 0=neck_roll, 1=shoulder_shrug, 2=finger_flex, 3=posture_shift
var _ambient_type: int          = -1
var _ambient_progress: float    = 0.0
## Which hand for finger_flex ambient: 0=left, 1=right
var _ambient_flex_hand: int     = 0

## Lunge attack state.
var _lunge_active: bool     = false
var _lunge_progress: float  = 0.0

## Cached arrays of finger bone indices for quick iteration.
var _finger_bones_left: Array[int]  = []
var _finger_bones_right: Array[int] = []
## Combined left + right finger cache — avoids per-roll allocation in idle twitches.
var _all_finger_bones: Array[int]   = []

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

	# Resolve and cache the neck bone index for procedural look-at.
	# find_bone() is used rather than hardcoding index 5 — a skeleton re-import
	# can change bone ordering, which would silently break a hardcoded index.
	_neck_bone_idx = _skeleton.find_bone("mixamorig_Neck_05")
	assert(_neck_bone_idx >= 0,
		"RitualWatcher: bone 'mixamorig_Neck_05' not found — " +
		"check skeleton was not re-imported with different bone names.")
	# Cache the rest rotation: the neck's T-pose anatomical tilt (~6° forward).
	# This is the neutral orientation we layer yaw on top of.
	_neck_rest_rotation = _skeleton.get_bone_rest(_neck_bone_idx).basis.get_rotation_quaternion()

	# Resolve ALL skeleton bone indices, rest rotations, and precomputed axes.
	var _all_bone_names: Array[String] = [
		"_rootJoint",
		"mixamorig_Hips_01",
		"mixamorig_Spine_02",
		"mixamorig_Spine1_03",
		"mixamorig_Spine2_04",
		"mixamorig_Neck_05",
		"mixamorig_Head_06",
		"mixamorig_HeadTop_End_07",
		"mixamorig_LeftShoulder_08",
		"mixamorig_LeftArm_09",
		"mixamorig_LeftForeArm_010",
		"mixamorig_LeftHand_011",
		"mixamorig_LeftHandThumb1_012",
		"mixamorig_LeftHandThumb2_013",
		"mixamorig_LeftHandThumb3_014",
		"mixamorig_LeftHandThumb4_015",
		"mixamorig_LeftHandIndex1_016",
		"mixamorig_LeftHandIndex2_017",
		"mixamorig_LeftHandIndex3_018",
		"mixamorig_LeftHandIndex4_019",
		"mixamorig_LeftHandMiddle1_020",
		"mixamorig_LeftHandMiddle2_021",
		"mixamorig_LeftHandMiddle3_022",
		"mixamorig_LeftHandMiddle4_023",
		"mixamorig_LeftHandRing1_024",
		"mixamorig_LeftHandRing2_025",
		"mixamorig_LeftHandRing3_026",
		"mixamorig_LeftHandRing4_027",
		"mixamorig_RightShoulder_028",
		"mixamorig_RightArm_029",
		"mixamorig_RightForeArm_030",
		"mixamorig_RightHand_031",
		"mixamorig_RightHandThumb1_032",
		"mixamorig_RightHandThumb2_033",
		"mixamorig_RightHandThumb3_034",
		"mixamorig_RightHandThumb4_035",
		"mixamorig_RightHandIndex1_036",
		"mixamorig_RightHandIndex2_037",
		"mixamorig_RightHandIndex3_038",
		"mixamorig_RightHandIndex4_039",
		"mixamorig_RightHandMiddle1_040",
		"mixamorig_RightHandMiddle2_041",
		"mixamorig_RightHandMiddle3_042",
		"mixamorig_RightHandMiddle4_043",
		"mixamorig_RightHandRing1_044",
		"mixamorig_RightHandRing2_045",
		"mixamorig_RightHandRing3_046",
		"mixamorig_RightHandRing4_047",
		"mixamorig_LeftUpLeg_048",
		"mixamorig_LeftLeg_049",
		"mixamorig_LeftFoot_050",
		"mixamorig_LeftToeBase_051",
		"mixamorig_RightUpLeg_053",
		"mixamorig_RightLeg_054",
		"mixamorig_RightFoot_055",
		"mixamorig_RightToeBase_00",
	]

	for bone_name: String in _all_bone_names:
		var idx: int = _skeleton.find_bone(bone_name)
		if idx >= 0:
			_bone_idx[bone_name] = idx
			_bone_rest_quat[idx] = _skeleton.get_bone_rest(idx).basis.get_rotation_quaternion()
			var bone_global_basis: Basis = _skeleton.get_bone_global_rest(idx).basis
			var inv_basis: Basis = bone_global_basis.transposed()
			_bone_sagittal_axis[idx] = (inv_basis * Vector3.RIGHT).normalized()
			_bone_lateral_axis[idx]  = (inv_basis * Vector3.FORWARD).normalized()
			_bone_vertical_axis[idx] = (inv_basis * Vector3.UP).normalized()

	# Cache finger bone arrays for quick iteration by idle/ambient/lunge layers.
	var _l_finger_names: Array[String] = [
		"mixamorig_LeftHandThumb1_012", "mixamorig_LeftHandThumb2_013",
		"mixamorig_LeftHandThumb3_014", "mixamorig_LeftHandThumb4_015",
		"mixamorig_LeftHandIndex1_016", "mixamorig_LeftHandIndex2_017",
		"mixamorig_LeftHandIndex3_018", "mixamorig_LeftHandIndex4_019",
		"mixamorig_LeftHandMiddle1_020", "mixamorig_LeftHandMiddle2_021",
		"mixamorig_LeftHandMiddle3_022", "mixamorig_LeftHandMiddle4_023",
		"mixamorig_LeftHandRing1_024", "mixamorig_LeftHandRing2_025",
		"mixamorig_LeftHandRing3_026", "mixamorig_LeftHandRing4_027",
	]
	var _r_finger_names: Array[String] = [
		"mixamorig_RightHandThumb1_032", "mixamorig_RightHandThumb2_033",
		"mixamorig_RightHandThumb3_034", "mixamorig_RightHandThumb4_035",
		"mixamorig_RightHandIndex1_036", "mixamorig_RightHandIndex2_037",
		"mixamorig_RightHandIndex3_038", "mixamorig_RightHandIndex4_039",
		"mixamorig_RightHandMiddle1_040", "mixamorig_RightHandMiddle2_041",
		"mixamorig_RightHandMiddle3_042", "mixamorig_RightHandMiddle4_043",
		"mixamorig_RightHandRing1_044", "mixamorig_RightHandRing2_045",
		"mixamorig_RightHandRing3_046", "mixamorig_RightHandRing4_047",
	]
	for fn: String in _l_finger_names:
		if _bone_idx.has(fn):
			_finger_bones_left.append(_bone_idx[fn])
	for fn: String in _r_finger_names:
		if _bone_idx.has(fn):
			_finger_bones_right.append(_bone_idx[fn])

	_all_finger_bones.append_array(_finger_bones_left)
	_all_finger_bones.append_array(_finger_bones_right)

	_ambient_next_trigger = randf_range(ambient_min_interval, ambient_max_interval)

	# Build constant rest-pose posture corrections (arm adduction, shoulder protraction).
	_build_posture_offsets()

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
	_update_look_at_player(delta)           # 7. look-at state machine (reads final rotation.y)
	_update_explore_head_scan(delta)        # 8. random neck scan during exploration
	_apply_neck_look()                      # 9. write neck bone pose from current yaw
	_update_walk_animation(delta)           # 10. procedural walk/run bone offsets
	_update_idle_animation(delta)           # 11. breathing, twitches, weight shift
	_update_ambient_animation(delta)        # 12. random ambient motions
	_update_lunge_animation(delta)          # 13. lunge attack when catching player
	_compose_and_apply_all_bones()          # 14. compose all layers and write to skeleton
	move_and_slide()                        # 15. apply velocity with Jolt physics
	_nav_agent.velocity = velocity          # 16. report actual velocity to nav agent
	_update_stuck_check(delta)              # 17. teleport to spawn if stuck while not hunting

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
	#   1. INVESTIGATE_SOUND   — react to loud noise on the same floor
	#   2. HUNT_PLAYER         — chase the player when close and on same floor
	#   3. PURSUE_LAST_KNOWN   — walk to the spot where the player last escaped
	#   4. EXPLORE             — roam idle
	var root := SelectorNode.new([investigate_seq, hunt_seq, last_known_seq, explore_seq])
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
			blackboard["is_hunting"] = true
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
		if not _lunge_active:
			_lunge_active = true
			_lunge_progress = 0.0
			trigger_player_caught.rpc()
	return BaseNode.Status.SUCCESS


# ── Actions: Pursue Last Known Branch ────────────────────────────────────────

## Navigate to the position where the player was last seen when hunt mode ended.
## Weeping Angel freeze still applies. Clears the target on arrival and falls
## through to exploration if the player has not re-entered hunt range.
func _action_pursue_last_known() -> int:
	# Weeping Angel: freeze while the player is watching.
	if blackboard["is_being_looked_at"]:
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
	if blackboard["is_being_looked_at"]:
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

	# Teleport to spawn once stuck time exceeds the threshold.
	if _stuck_timer >= stuck_timeout:
		_stuck_timer          = 0.0
		_stuck_sample_elapsed = 0.0
		_stuck_sample_pos     = _spawn_position
		global_position       = _spawn_position
		velocity              = Vector3.ZERO
		_compute_path_to(_spawn_position)
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
		if _body_look_active:
			rotation.y = lerp_angle(rotation.y, _body_look_target_angle, body_look_speed * delta)
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
	# Layer a weaker pull toward the player when body look is active.
	# body_look_speed (2.0) < rotation_speed (5.0) so movement direction dominates.
	if _body_look_active:
		rotation.y = lerp_angle(rotation.y, _body_look_target_angle, body_look_speed * delta)


# ── Procedural Look-At ───────────────────────────────────────────────────────

## Drives the five-stage neck/body look-at sequence.
## Runs after _apply_movement() so rotation.y is this frame's final body angle,
## giving an accurate neck yaw offset with no visible lag.
func _update_look_at_player(delta: float) -> void:
	if not is_instance_valid(player_node):
		_body_look_active = false
		_neck_target_yaw  = 0.0
		_neck_current_yaw = lerpf(_neck_current_yaw, 0.0, neck_rotation_speed * delta)
		return

	var dist: float = blackboard["distance_to_player"]

	match _look_state:

		LookState.IDLE:
			if dist <= look_detect_radius:
				_look_state       = LookState.DELAY_NECK
				_look_state_timer = 0.0

		LookState.DELAY_NECK:
			if dist > look_detect_radius:
				# Player left before delay expired — neck never moved, go straight back.
				_look_state = LookState.IDLE
				return
			_look_state_timer += delta
			if _look_state_timer >= neck_track_delay:
				_look_state       = LookState.TRACKING_NECK
				_look_state_timer = 0.0

		LookState.TRACKING_NECK:
			if dist > look_detect_radius:
				_look_state = LookState.RETURNING
				return
			_neck_target_yaw   = _compute_neck_yaw_to_player()
			_look_state_timer += delta
			if _look_state_timer >= body_track_delay:
				_look_state       = LookState.TRACKING_FULL
				_look_state_timer = 0.0
				_body_look_active = true

		LookState.TRACKING_FULL:
			if dist > look_detect_radius:
				_look_state       = LookState.RETURNING
				_body_look_active = false
				return
			_body_look_active       = true
			_neck_target_yaw        = _compute_neck_yaw_to_player()
			_body_look_target_angle = _compute_body_look_angle()

		LookState.RETURNING:
			_neck_target_yaw  = 0.0
			_body_look_active = false
			if absf(_neck_current_yaw) < deg_to_rad(1.0):
				_neck_current_yaw = 0.0
				_look_state = LookState.IDLE
				# Re-enter delay immediately if the player is still nearby.
				if dist <= look_detect_radius:
					_look_state       = LookState.DELAY_NECK
					_look_state_timer = 0.0

	# Lerp neck yaw toward target every frame regardless of state.
	# In RETURNING, target is 0 so this naturally blends the neck back to rest.
	_neck_current_yaw = lerpf(_neck_current_yaw, _neck_target_yaw, neck_rotation_speed * delta)


## Returns the signed yaw offset (radians) from the body's current forward to
## the player direction, clamped to ±neck_yaw_clamp_deg.
func _compute_neck_yaw_to_player() -> float:
	var to_player: Vector3 = player_node.global_position - global_position
	to_player.y = 0.0
	if to_player.length_squared() < 0.0001:
		return 0.0
	to_player = to_player.normalized()
	# atan2(x, z) produces a world-space yaw consistent with rotation.y convention.
	var world_angle: float = atan2(to_player.x, to_player.z)
	# wrapf gives the shortest signed difference, guaranteed in [-PI, PI].
	var yaw_offset: float  = wrapf(world_angle - rotation.y, -PI, PI)
	return clampf(yaw_offset, -deg_to_rad(neck_yaw_clamp_deg), deg_to_rad(neck_yaw_clamp_deg))


## Returns the world-space yaw angle toward the player for body rotation.
func _compute_body_look_angle() -> float:
	var to_player: Vector3 = player_node.global_position - global_position
	to_player.y = 0.0
	if to_player.length_squared() < 0.0001:
		return rotation.y
	return atan2(to_player.x, to_player.z)


## Writes the current neck yaw to the Skeleton3D bone pose.
##
## Quaternion math:
##   goal = yaw_quat * _neck_rest_rotation
##   Reading right-to-left: first the rest rotation places the neck in its
##   anatomical ~6° forward tilt (in parent bone space), then yaw_quat rotates
##   THAT result around the parent/world Y axis by _neck_current_yaw radians.
##
##   Order matters: reversing it would yaw around the neck's own tilted local Y,
##   producing off-axis wobble.
##
##   At _neck_current_yaw == 0.0: goal == _neck_rest_rotation — exact T-pose rest,
##   so the transition back to animation control produces no visible pop.
func _apply_neck_look() -> void:
	if _neck_bone_idx < 0:
		return
	var yaw: float
	if _look_state == LookState.IDLE:
		# In IDLE the player-tracker is inactive; use the explore scan yaw instead.
		yaw = _explore_head_yaw
		if absf(yaw) < 0.001:
			return  # nothing to write; let skeleton render the rest pose
	else:
		yaw = _neck_current_yaw
	var yaw_quat: Quaternion = Quaternion(Vector3.UP, yaw)
	_skeleton.set_bone_pose_rotation(_neck_bone_idx, yaw_quat * _neck_rest_rotation)


## Drives random neck yaw during exploration.
## Only active when look state is IDLE (no player tracking) and no priority
## behaviour is running.  Smoothly returns to 0 when any other state engages.
func _update_explore_head_scan(delta: float) -> void:
	var active: bool = (
		_look_state == LookState.IDLE
		and not blackboard["is_hunting"]
		and not blackboard["has_sound_target"]
		and not blackboard["has_last_known_target"]
	)
	if not active:
		_explore_head_yaw = lerpf(_explore_head_yaw, 0.0, neck_rotation_speed * delta)
		return
	_explore_head_scan_timer += delta
	if _explore_head_scan_timer >= _explore_head_scan_next:
		_explore_head_scan_timer = 0.0
		_explore_head_scan_next  = randf_range(
			explore_head_scan_min_interval, explore_head_scan_max_interval
		)
		_explore_head_target_yaw = randf_range(
			-deg_to_rad(explore_head_scan_range_deg),
			 deg_to_rad(explore_head_scan_range_deg)
		)
	_explore_head_yaw = lerpf(
		_explore_head_yaw, _explore_head_target_yaw, explore_head_scan_speed * delta
	)


# ── Bone Animation Helpers ───────────────────────────────────────────────────

## Shorthand to look up a bone index from its name.
## Returns -1 if the name was not cached.
func _bi(bone_name: String) -> int:
	return _bone_idx.get(bone_name, -1)


## Store an idle-layer rotation offset for a bone (by index).
func _idle_offset_idx(idx: int, axis: Vector3, angle: float) -> void:
	if idx < 0:
		return
	if _idle_offsets.has(idx):
		_idle_offsets[idx] = _idle_offsets[idx] * Quaternion(axis, angle)
	else:
		_idle_offsets[idx] = Quaternion(axis, angle)


## Store an ambient-layer rotation offset for a bone (by index).
func _ambient_offset_idx(idx: int, axis: Vector3, angle: float) -> void:
	if idx < 0:
		return
	if _ambient_offsets.has(idx):
		_ambient_offsets[idx] = _ambient_offsets[idx] * Quaternion(axis, angle)
	else:
		_ambient_offsets[idx] = Quaternion(axis, angle)


## Store a lunge-layer rotation offset for a bone (by index).
func _lunge_offset_idx(idx: int, axis: Vector3, angle: float) -> void:
	if idx < 0:
		return
	if _lunge_offsets.has(idx):
		_lunge_offsets[idx] = _lunge_offsets[idx] * Quaternion(axis, angle)
	else:
		_lunge_offsets[idx] = Quaternion(axis, angle)


## Builds the constant rest-pose posture correction dictionary.
## Called once in _ready() after all bone indices are resolved.
## Re-call if arm_adduction_angle / shoulder_protract_angle exports are changed.
func _build_posture_offsets() -> void:
	_posture_offsets.clear()
	# Upper arms: adduct from T-pose horizontal toward a natural hang.
	# _bone_lateral_axis aligns with world -Z; positive angle adducts left arm,
	# negative angle adducts right arm (opposing T-pose directions).
	var la: int = _bi("mixamorig_LeftArm_09")
	if la >= 0:
		_posture_offsets[la] = Quaternion(_bone_lateral_axis[la],  arm_adduction_angle)
	var ra: int = _bi("mixamorig_RightArm_029")
	if ra >= 0:
		_posture_offsets[ra] = Quaternion(_bone_lateral_axis[ra], -arm_adduction_angle)
	# Shoulders: protract forward to close the gap between upper arm and torso.
	# _bone_vertical_axis aligns with world +Y; rotating around it moves the
	# shoulder tip forward (-Z) for the left side and matching for right.
	var ls: int = _bi("mixamorig_LeftShoulder_08")
	if ls >= 0:
		_posture_offsets[ls] = Quaternion(_bone_vertical_axis[ls],  shoulder_protract_angle)
	var rs: int = _bi("mixamorig_RightShoulder_028")
	if rs >= 0:
		_posture_offsets[rs] = Quaternion(_bone_vertical_axis[rs], -shoulder_protract_angle)
	# Forearms: slight natural resting elbow bend.
	var lfa: int = _bi("mixamorig_LeftForeArm_010")
	if lfa >= 0:
		_posture_offsets[lfa] = Quaternion(_bone_lateral_axis[lfa],  elbow_rest_bend)
	var rfa: int = _bi("mixamorig_RightForeArm_030")
	if rfa >= 0:
		_posture_offsets[rfa] = Quaternion(_bone_lateral_axis[rfa], -elbow_rest_bend)


## Compose all layer offsets and write final bone poses.
## Neck bone is skipped when owned by the look-at system (not IDLE) or when the
## explore head scan has active yaw — _apply_neck_look() owns it in those cases.
func _compose_and_apply_all_bones() -> void:
	for idx: int in _bone_rest_quat:
		if idx == _neck_bone_idx and (_look_state != LookState.IDLE or absf(_explore_head_yaw) >= 0.001):
			continue  # Neck owned by look-at or explore scan; _apply_neck_look() handles it
		var final_offset: Quaternion = Quaternion.IDENTITY
		if _walk_offsets.has(idx):
			final_offset = final_offset * _walk_offsets[idx]
		if _idle_offsets.has(idx):
			final_offset = final_offset * _idle_offsets[idx]
		if _ambient_offsets.has(idx):
			final_offset = final_offset * _ambient_offsets[idx]
		if _lunge_offsets.has(idx):
			final_offset = final_offset * _lunge_offsets[idx]
		if _posture_offsets.has(idx):
			final_offset = final_offset * _posture_offsets[idx]
		_skeleton.set_bone_pose_rotation(idx, _bone_rest_quat[idx] * final_offset)


# ── Walk / Run Animation ────────────────────────────────────────────────────

func _update_walk_animation(delta: float) -> void:
	_walk_offsets.clear()
	var xz_speed: float = Vector2(velocity.x, velocity.z).length()

	if xz_speed > 0.05:
		_walk_cycle      += delta * xz_speed * walk_cycle_speed
		_walk_anim_weight = move_toward(_walk_anim_weight, 1.0, walk_blend_in_speed * delta)
	else:
		_walk_anim_weight = move_toward(_walk_anim_weight, 0.0, walk_blend_out_speed * delta)

	# ── Run blend: transitions to run parameters during hunt state ────────
	var _is_running: bool = blackboard["is_hunting"] and _current_speed > 0.5
	_run_blend_weight = move_toward(
		_run_blend_weight, 1.0 if _is_running else 0.0, run_blend_speed * delta
	)
	var rw: float = _run_blend_weight

	# Pre-blended amplitude locals — avoids repeating lerp calls per-bone.
	var _leg_amp:   float = lerpf(walk_leg_swing_amp,  run_leg_swing_amp,   rw)
	var _knee_amp:  float = lerpf(walk_knee_bend_amp,  run_knee_bend_amp,   rw)
	var _arm_amp:   float = lerpf(walk_arm_swing_amp,  run_arm_swing_amp,   rw)
	var _elbow_amp: float = lerpf(walk_elbow_bend_amp, run_elbow_bend_amp,  rw)
	var _hip_sway_amp_blended: float = lerpf(walk_hip_sway_amp, run_hip_sway_amp, rw)
	var _hip_bob_amp_blended:  float = lerpf(walk_hip_bob_amp,  run_hip_bob_amp,  rw)

	# Decay footfall impact impulses (runs regardless of walk weight so they finish).
	_impact_left  = move_toward(_impact_left,  0.0, footfall_decay_rate * delta)
	_impact_right = move_toward(_impact_right, 0.0, footfall_decay_rate * delta)

	if _walk_anim_weight < 0.001:
		return

	var w: float = _walk_anim_weight
	var t: float = _walk_cycle

	# ── Phase values (asymmetric for horror limp) ─────────────────────────
	var left_leg: float   = sin(t)
	var right_leg: float  = sin(t + PI + walk_asymmetry)
	# Contralateral arm swing.
	var left_arm: float   = right_leg
	var right_arm: float  = left_leg

	# ── Footfall detection: positive → negative zero-crossing = foot plant ─
	if left_leg  < 0.0 and _prev_left_phase  >= 0.0:
		_impact_left  = 1.0
	if right_leg < 0.0 and _prev_right_phase >= 0.0:
		_impact_right = 1.0
	_prev_left_phase  = left_leg
	_prev_right_phase = right_leg

	# Hip sway (lateral roll).
	var hip_sway: float   = sin(t) * _hip_sway_amp_blended * w
	# Hip vertical bob at double frequency.
	var hip_bob: float    = sin(2.0 * t) * _hip_bob_amp_blended * w

	# Knee bends only during the swing/lift phase.
	var l_knee: float     = maxf(0.0,  left_leg) * _knee_amp * w
	var r_knee: float     = maxf(0.0, right_leg) * _knee_amp * w
	# Foot counter-rotation.
	var l_foot: float     = -l_knee * 0.5
	var r_foot: float     = -r_knee * 0.5
	# Toe push-off.
	var l_toe: float      = maxf(0.0, -left_leg) * walk_toe_amp * w
	var r_toe: float      = maxf(0.0, -right_leg) * walk_toe_amp * w

	# Spine chain undulation with progressive phase delay.
	var spine_sway: float  = -hip_sway * 0.5
	var spine1_sway: float = sin(t - 0.2) * walk_spine1_amp * w
	var spine2_sway: float = sin(t - 0.4) * walk_spine2_amp * w

	# Shoulder rise on contralateral step.
	var l_shoulder_rise: float = maxf(0.0, right_leg) * walk_shoulder_amp * w
	var r_shoulder_rise: float = maxf(0.0, left_leg) * walk_shoulder_amp * w

	# ── Apply bone offsets using precomputed axes ─────────────────────────

	# Hips: lateral sway + vertical bob + footfall impact compression.
	var hips_idx: int = _bi("mixamorig_Hips_01")
	if hips_idx >= 0:
		var sway_q: Quaternion   = Quaternion(_bone_lateral_axis[hips_idx], hip_sway)
		var bob_q: Quaternion    = Quaternion(_bone_sagittal_axis[hips_idx], hip_bob)
		var impact_total: float  = (_impact_left + _impact_right) * footfall_impact_amp * w
		var impact_q: Quaternion = Quaternion(_bone_sagittal_axis[hips_idx], -impact_total)
		_walk_offsets[hips_idx] = sway_q * bob_q * impact_q

	# Spine chain (lateral sway + forward lean at run blend weight + footfall spine snap).
	var impact_spine: float = (_impact_left + _impact_right) * footfall_impact_amp * 0.4 * w
	var run_lean: float     = run_spine_lean * rw * w
	var spine_idx: int = _bi("mixamorig_Spine_02")
	if spine_idx >= 0:
		var lat_q:    Quaternion = Quaternion(_bone_lateral_axis[spine_idx],   spine_sway)
		var lean_q:   Quaternion = Quaternion(_bone_sagittal_axis[spine_idx],  run_lean * 0.33 + impact_spine)
		_walk_offsets[spine_idx] = lat_q * lean_q
	var spine1_idx: int = _bi("mixamorig_Spine1_03")
	if spine1_idx >= 0:
		var lat_q:  Quaternion = Quaternion(_bone_lateral_axis[spine1_idx],  spine1_sway)
		var lean_q: Quaternion = Quaternion(_bone_sagittal_axis[spine1_idx], run_lean * 0.33)
		_walk_offsets[spine1_idx] = lat_q * lean_q
	var spine2_idx: int = _bi("mixamorig_Spine2_04")
	if spine2_idx >= 0:
		var lat_q:  Quaternion = Quaternion(_bone_lateral_axis[spine2_idx],  spine2_sway)
		var lean_q: Quaternion = Quaternion(_bone_sagittal_axis[spine2_idx], run_lean * 0.33)
		_walk_offsets[spine2_idx] = lat_q * lean_q

	# Left leg chain.
	var l_upper_idx: int = _bi("mixamorig_LeftUpLeg_048")
	if l_upper_idx >= 0:
		_walk_offsets[l_upper_idx] = Quaternion(_bone_sagittal_axis[l_upper_idx], left_leg * _leg_amp * w)
	var l_knee_idx: int = _bi("mixamorig_LeftLeg_049")
	if l_knee_idx >= 0:
		_walk_offsets[l_knee_idx] = Quaternion(_bone_sagittal_axis[l_knee_idx], l_knee)
	var l_foot_idx: int = _bi("mixamorig_LeftFoot_050")
	if l_foot_idx >= 0:
		_walk_offsets[l_foot_idx] = Quaternion(_bone_sagittal_axis[l_foot_idx], l_foot)
	var l_toe_idx: int = _bi("mixamorig_LeftToeBase_051")
	if l_toe_idx >= 0:
		_walk_offsets[l_toe_idx] = Quaternion(_bone_sagittal_axis[l_toe_idx], l_toe)

	# Right leg chain.
	var r_upper_idx: int = _bi("mixamorig_RightUpLeg_053")
	if r_upper_idx >= 0:
		_walk_offsets[r_upper_idx] = Quaternion(_bone_sagittal_axis[r_upper_idx], right_leg * _leg_amp * w)
	var r_knee_idx: int = _bi("mixamorig_RightLeg_054")
	if r_knee_idx >= 0:
		_walk_offsets[r_knee_idx] = Quaternion(_bone_sagittal_axis[r_knee_idx], r_knee)
	var r_foot_idx: int = _bi("mixamorig_RightFoot_055")
	if r_foot_idx >= 0:
		_walk_offsets[r_foot_idx] = Quaternion(_bone_sagittal_axis[r_foot_idx], r_foot)
	var r_toe_idx: int = _bi("mixamorig_RightToeBase_00")
	if r_toe_idx >= 0:
		_walk_offsets[r_toe_idx] = Quaternion(_bone_sagittal_axis[r_toe_idx], r_toe)

	# Shoulders (slight rise on contralateral step + constant forward hunch).
	var l_sh_idx: int = _bi("mixamorig_LeftShoulder_08")
	if l_sh_idx >= 0:
		var rise_q: Quaternion  = Quaternion(_bone_lateral_axis[l_sh_idx], l_shoulder_rise)
		var hunch_q: Quaternion = Quaternion(_bone_sagittal_axis[l_sh_idx], 0.05 * w)
		_walk_offsets[l_sh_idx] = rise_q * hunch_q
	var r_sh_idx: int = _bi("mixamorig_RightShoulder_028")
	if r_sh_idx >= 0:
		var rise_q: Quaternion  = Quaternion(_bone_lateral_axis[r_sh_idx], r_shoulder_rise)
		var hunch_q: Quaternion = Quaternion(_bone_sagittal_axis[r_sh_idx], 0.05 * w)
		_walk_offsets[r_sh_idx] = rise_q * hunch_q

	# Left arm (contralateral swing — left arm with right leg, swings wider).
	var l_arm_idx: int = _bi("mixamorig_LeftArm_09")
	if l_arm_idx >= 0:
		_walk_offsets[l_arm_idx] = Quaternion(_bone_sagittal_axis[l_arm_idx], left_arm * _arm_amp * walk_left_arm_factor * w)
	var l_fa_idx: int = _bi("mixamorig_LeftForeArm_010")
	if l_fa_idx >= 0:
		_walk_offsets[l_fa_idx] = Quaternion(_bone_sagittal_axis[l_fa_idx], maxf(0.0, left_arm) * _elbow_amp * w)

	# Right arm.
	var r_arm_idx: int = _bi("mixamorig_RightArm_029")
	if r_arm_idx >= 0:
		_walk_offsets[r_arm_idx] = Quaternion(_bone_sagittal_axis[r_arm_idx], right_arm * _arm_amp * w)
	var r_fa_idx: int = _bi("mixamorig_RightForeArm_030")
	if r_fa_idx >= 0:
		_walk_offsets[r_fa_idx] = Quaternion(_bone_sagittal_axis[r_fa_idx], maxf(0.0, right_arm) * _elbow_amp * w)

	# Hands — slight wrist rotation during walk.
	var l_hand_idx: int = _bi("mixamorig_LeftHand_011")
	if l_hand_idx >= 0:
		_walk_offsets[l_hand_idx] = Quaternion(_bone_lateral_axis[l_hand_idx], sin(t) * 0.05 * w)
	var r_hand_idx: int = _bi("mixamorig_RightHand_031")
	if r_hand_idx >= 0:
		_walk_offsets[r_hand_idx] = Quaternion(_bone_lateral_axis[r_hand_idx], sin(t + PI) * 0.05 * w)

	# Fingers curl slightly inward during walk (predatory claw look).
	var finger_curl: float = walk_finger_curl_amp * w
	for fidx: int in _finger_bones_left:
		if _bone_sagittal_axis.has(fidx):
			_walk_offsets[fidx] = Quaternion(_bone_sagittal_axis[fidx], finger_curl)
	for fidx: int in _finger_bones_right:
		if _bone_sagittal_axis.has(fidx):
			_walk_offsets[fidx] = Quaternion(_bone_sagittal_axis[fidx], finger_curl)


# ── Idle Animation ──────────────────────────────────────────────────────────

func _update_idle_animation(delta: float) -> void:
	_idle_offsets.clear()
	_idle_time += delta

	# Idle blends inversely with walk: fully active when still, fades during walk.
	var idle_weight: float = 1.0 - _walk_anim_weight
	if idle_weight < 0.001:
		return

	var breath: float = sin(_idle_time * idle_breath_speed * TAU)
	var iw: float = idle_weight

	# Breathing — spine chain expands/contracts.
	var spine_idx: int = _bi("mixamorig_Spine_02")
	if spine_idx >= 0:
		_idle_offset_idx(spine_idx, _bone_sagittal_axis[spine_idx], breath * idle_breath_spine_amp * iw)
	var spine1_idx: int = _bi("mixamorig_Spine1_03")
	if spine1_idx >= 0:
		_idle_offset_idx(spine1_idx, _bone_sagittal_axis[spine1_idx], breath * idle_breath_spine_amp * 0.7 * iw)
	var spine2_idx: int = _bi("mixamorig_Spine2_04")
	if spine2_idx >= 0:
		_idle_offset_idx(spine2_idx, _bone_sagittal_axis[spine2_idx], breath * idle_breath_spine_amp * 0.4 * iw)

	# Shoulders rise/fall with breathing.
	var l_sh_idx: int = _bi("mixamorig_LeftShoulder_08")
	if l_sh_idx >= 0:
		_idle_offset_idx(l_sh_idx, _bone_vertical_axis[l_sh_idx], breath * idle_breath_shoulder_amp * iw)
	var r_sh_idx: int = _bi("mixamorig_RightShoulder_028")
	if r_sh_idx >= 0:
		_idle_offset_idx(r_sh_idx, _bone_vertical_axis[r_sh_idx], breath * idle_breath_shoulder_amp * iw)

	# Hips — subtle weight shifting side to side.
	var hips_idx: int = _bi("mixamorig_Hips_01")
	if hips_idx >= 0:
		var shift: float = sin(_idle_time * idle_weight_shift_speed * TAU) * idle_weight_shift_amp * iw
		_idle_offset_idx(hips_idx, _bone_lateral_axis[hips_idx], shift)

	# Hips — subtle vertical breathing bob.
	if hips_idx >= 0:
		_idle_offset_idx(hips_idx, _bone_sagittal_axis[hips_idx], breath * 0.01 * iw)

	# Hands — slight wrist fidget.
	var l_hand_idx: int = _bi("mixamorig_LeftHand_011")
	if l_hand_idx >= 0:
		_idle_offset_idx(l_hand_idx, _bone_lateral_axis[l_hand_idx], sin(_idle_time * 0.8) * 0.03 * iw)
	var r_hand_idx: int = _bi("mixamorig_RightHand_031")
	if r_hand_idx >= 0:
		_idle_offset_idx(r_hand_idx, _bone_lateral_axis[r_hand_idx], sin(_idle_time * 0.6) * 0.03 * iw)

	# Feet — subtle weight shifting.
	var l_foot_idx: int = _bi("mixamorig_LeftFoot_050")
	if l_foot_idx >= 0:
		_idle_offset_idx(l_foot_idx, _bone_lateral_axis[l_foot_idx], sin(_idle_time * idle_weight_shift_speed * TAU + PI * 0.5) * 0.01 * iw)
	var r_foot_idx: int = _bi("mixamorig_RightFoot_055")
	if r_foot_idx >= 0:
		_idle_offset_idx(r_foot_idx, _bone_lateral_axis[r_foot_idx], sin(_idle_time * idle_weight_shift_speed * TAU - PI * 0.5) * 0.01 * iw)

	# Random finger micro-twitches.
	if _idle_finger_twitch_bone < 0:
		# No active twitch — roll for a new one.
		if randf() < idle_finger_twitch_chance:
			if _all_finger_bones.size() > 0:
				_idle_finger_twitch_bone = _all_finger_bones[randi() % _all_finger_bones.size()]
				_idle_finger_twitch_progress = 0.0
	else:
		# Advance the current twitch.
		_idle_finger_twitch_progress += delta * 4.0
		if _idle_finger_twitch_progress >= 1.0:
			_idle_finger_twitch_bone = -1
		else:
			# Quick curl then release (sin peak at 0.5).
			var twitch_angle: float = sin(_idle_finger_twitch_progress * PI) * 0.3 * iw
			if _bone_sagittal_axis.has(_idle_finger_twitch_bone):
				_idle_offset_idx(_idle_finger_twitch_bone, _bone_sagittal_axis[_idle_finger_twitch_bone], twitch_angle)

	# Head micro-tremor (only when look-at is idle).
	if _look_state == LookState.IDLE:
		var head_idx: int = _bi("mixamorig_Head_06")
		if head_idx >= 0:
			var tremor_x: float = sin(_idle_time * 3.7) * 0.008 * iw
			var tremor_z: float = sin(_idle_time * 2.3) * 0.005 * iw
			_idle_offset_idx(head_idx, _bone_sagittal_axis[head_idx], tremor_x)
			_idle_offset_idx(head_idx, _bone_lateral_axis[head_idx], tremor_z)


# ── Ambient Animation ───────────────────────────────────────────────────────

func _update_ambient_animation(delta: float) -> void:
	_ambient_offsets.clear()

	# Suppressed during lunge.
	if _lunge_active:
		return

	if not _ambient_active:
		_ambient_timer += delta
		if _ambient_timer >= _ambient_next_trigger:
			_ambient_active = true
			_ambient_progress = 0.0
			_ambient_timer = 0.0
			# Pick a random ambient type. Skip neck_roll if look-at is active.
			var choices: Array[int] = [1, 2, 3]  # shoulder_shrug, finger_flex, posture_shift
			if _look_state == LookState.IDLE:
				choices.append(0)  # neck_roll allowed
			_ambient_type = choices[randi() % choices.size()]
			if _ambient_type == 2:
				_ambient_flex_hand = randi() % 2
		return

	_ambient_progress += delta / ambient_anim_duration
	if _ambient_progress >= 1.0:
		_ambient_active = false
		_ambient_next_trigger = randf_range(ambient_min_interval, ambient_max_interval)
		return

	# Smooth envelope: ease in and out.
	var envelope: float = sin(_ambient_progress * PI)

	match _ambient_type:
		0:  # Neck roll: left → center → right → center
			var neck_idx: int = _bi("mixamorig_Neck_05")
			if neck_idx >= 0 and _look_state == LookState.IDLE:
				var roll_angle: float = sin(_ambient_progress * TAU) * 0.15 * envelope
				_ambient_offset_idx(neck_idx, _bone_lateral_axis[neck_idx], roll_angle)

		1:  # Shoulder shrug: both shoulders rise then lower.
			var l_sh_idx: int = _bi("mixamorig_LeftShoulder_08")
			var r_sh_idx: int = _bi("mixamorig_RightShoulder_028")
			var shrug: float = envelope * 0.1
			if l_sh_idx >= 0:
				_ambient_offset_idx(l_sh_idx, _bone_vertical_axis[l_sh_idx], shrug)
			if r_sh_idx >= 0:
				_ambient_offset_idx(r_sh_idx, _bone_vertical_axis[r_sh_idx], shrug)

		2:  # Finger flex: one hand curls closed then open.
			var hand_fingers: Array[int] = _finger_bones_left if _ambient_flex_hand == 0 else _finger_bones_right
			var curl: float = envelope * 0.35
			for fidx: int in hand_fingers:
				if _bone_sagittal_axis.has(fidx):
					_ambient_offset_idx(fidx, _bone_sagittal_axis[fidx], curl)

		3:  # Posture shift: hips shift laterally, spine compensates.
			var hips_idx: int = _bi("mixamorig_Hips_01")
			var spine_idx: int = _bi("mixamorig_Spine_02")
			var shift: float = envelope * 0.06
			if hips_idx >= 0:
				_ambient_offset_idx(hips_idx, _bone_lateral_axis[hips_idx], shift)
			if spine_idx >= 0:
				_ambient_offset_idx(spine_idx, _bone_lateral_axis[spine_idx], -shift * 0.7)


# ── Lunge Attack Animation ──────────────────────────────────────────────────

func _update_lunge_animation(delta: float) -> void:
	_lunge_offsets.clear()

	if not _lunge_active:
		return

	_lunge_progress += delta / lunge_duration
	if _lunge_progress >= 1.0:
		_lunge_active = false
		return

	# Fast attack (ease-in over first 30%), slow retract (ease-out).
	var attack_env: float
	if _lunge_progress < 0.3:
		attack_env = smoothstep(0.0, 0.3, _lunge_progress)
	else:
		attack_env = smoothstep(1.0, 0.3, _lunge_progress)

	# Spine chain leans forward.
	for sn: String in ["mixamorig_Spine_02", "mixamorig_Spine1_03", "mixamorig_Spine2_04"]:
		var idx: int = _bi(sn)
		if idx >= 0:
			_lunge_offset_idx(idx, _bone_sagittal_axis[idx], lunge_spine_lean_amp * attack_env * 0.5)

	# Hips thrust forward.
	var hips_idx: int = _bi("mixamorig_Hips_01")
	if hips_idx >= 0:
		_lunge_offset_idx(hips_idx, _bone_sagittal_axis[hips_idx], lunge_spine_lean_amp * attack_env * 0.3)

	# Both shoulders roll forward aggressively.
	for sn: String in ["mixamorig_LeftShoulder_08", "mixamorig_RightShoulder_028"]:
		var idx: int = _bi(sn)
		if idx >= 0:
			_lunge_offset_idx(idx, _bone_sagittal_axis[idx], 0.3 * attack_env)

	# Arms extend forward.
	for sn: String in ["mixamorig_LeftArm_09", "mixamorig_RightArm_029"]:
		var idx: int = _bi(sn)
		if idx >= 0:
			_lunge_offset_idx(idx, _bone_sagittal_axis[idx], lunge_arm_extend_amp * attack_env)

	# Forearms straighten.
	for sn: String in ["mixamorig_LeftForeArm_010", "mixamorig_RightForeArm_030"]:
		var idx: int = _bi(sn)
		if idx >= 0:
			_lunge_offset_idx(idx, _bone_sagittal_axis[idx], lunge_arm_extend_amp * 0.6 * attack_env)

	# Hands flex.
	for sn: String in ["mixamorig_LeftHand_011", "mixamorig_RightHand_031"]:
		var idx: int = _bi(sn)
		if idx >= 0:
			_lunge_offset_idx(idx, _bone_sagittal_axis[idx], 0.2 * attack_env)

	# Fingers spread open then clench during attack.
	var finger_angle: float
	if _lunge_progress < 0.3:
		finger_angle = -lunge_finger_spread * attack_env  # Spread open
	else:
		finger_angle = lunge_finger_spread * attack_env  # Clench
	for fidx: int in _finger_bones_left:
		if _bone_sagittal_axis.has(fidx):
			_lunge_offset_idx(fidx, _bone_sagittal_axis[fidx], finger_angle)
	for fidx: int in _finger_bones_right:
		if _bone_sagittal_axis.has(fidx):
			_lunge_offset_idx(fidx, _bone_sagittal_axis[fidx], finger_angle)


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
