extends CharacterBody3D

@export var look_radius: float = 12.0
@export var neck_bone_name: String = "Neck"

# delay before monster reacts
@export var min_reaction_time: float = 1.0
@export var max_reaction_time: float = 2.5

# neck movement speed
@export var neck_turn_speed: float = 3.0

@onready var skeleton: Skeleton3D = $MeshInstance3D/Skeleton3D

var player: Node3D
var neck_bone_idx: int

var player_in_zone := false
var can_look := false
var reaction_timer := 0.0


func _ready():

    player = get_tree().get_first_node_in_group("player")
    neck_bone_idx = skeleton.find_bone(neck_bone_name)

    if neck_bone_idx == -1:
        print("Neck bone not found!")


func _process(delta):

    if player == null:
        return

    var dist = global_position.distance_to(player.global_position)

    # player enters detection radius
    if dist < look_radius:

        if !player_in_zone:
            player_in_zone = true
            start_reaction_timer()

        if can_look:
            look_at_player(delta)

    else:
        player_in_zone = false
        can_look = false
        reset_neck()


func start_reaction_timer():

    can_look = false

    reaction_timer = randf_range(min_reaction_time, max_reaction_time)

    await get_tree().create_timer(reaction_timer).timeout

    if player_in_zone:
        can_look = true


func look_at_player(delta):

    var bone_global := skeleton.get_bone_global_pose(neck_bone_idx)

    var target_dir = (player.global_position - bone_global.origin).normalized()

    # limit vertical neck rotation
    target_dir.y = clamp(target_dir.y, -0.5, 0.5)

    var target_basis := Basis().looking_at(target_dir, Vector3.UP)

    var target_transform := Transform3D(target_basis, bone_global.origin)

    var new_pose := bone_global.interpolate_with(target_transform, delta * neck_turn_speed)

    skeleton.set_bone_global_pose_override(
        neck_bone_idx,
        new_pose,
        1.0,
        true
    )


func reset_neck():

    skeleton.clear_bones_global_pose_override()