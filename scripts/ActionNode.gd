class_name ActionNode
extends BaseNode

## ── ActionNode ────────────────────────────────────────────────────────────────
##
## Leaf node that executes an action callable.
## The callable must return an int matching BaseNode.Status.
## Can return RUNNING to indicate the action continues next tick.
##
## Usage:
##   var node := ActionNode.new(func() -> int: return BaseNode.Status.SUCCESS)
##   # Or pass a named method reference:
##   var node := ActionNode.new(_my_action_method)


# ── State ──────────────────────────────────────────────────────────────────────

## The action to execute. Must return int (BaseNode.Status) and take no arguments.
var _action: Callable


# ── Constructor ────────────────────────────────────────────────────────────────

## action: a Callable that takes no arguments and returns int (BaseNode.Status).
func _init(action: Callable) -> void:
	_action = action


# ── Tick ──────────────────────────────────────────────────────────────────────

func tick() -> int:
	return _action.call()
