class_name BehaviorTree
extends Node

## ── BehaviorTree ──────────────────────────────────────────────────────────────
##
## Behaviour Tree manager. Attach as a child Node of the AI CharacterBody3D.
## Call tick() manually from the owning node's _physics_process(), AFTER
## updating all blackboard sensor values and AFTER the authority check.
##
## Do NOT enable auto _physics_process on this node — the owner controls timing.
##
## Setup:
##   1. Add BehaviorTree as a child node in your scene.
##   2. Attach this script.
##   3. In the owner's _ready(), call behavior_tree.set_root(root_node).
##   4. In the owner's _physics_process(), call behavior_tree.tick().


# ── State ──────────────────────────────────────────────────────────────────────

var _root: BaseNode = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Disable automatic processing — tick() is called manually by the owner.
	set_physics_process(false)
	set_process(false)


# ── Public API ────────────────────────────────────────────────────────────────

## Set the root node before the first tick.
## Call this from the AI owner's _ready() after building the tree.
func set_root(root: BaseNode) -> void:
	_root = root


## Execute one full evaluation pass of the behaviour tree.
## Call this from the AI owner's _physics_process() each frame.
func tick() -> void:
	if _root != null:
		_root.tick()
