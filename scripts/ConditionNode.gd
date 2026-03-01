class_name ConditionNode
extends BaseNode

## ── ConditionNode ─────────────────────────────────────────────────────────────
##
## Leaf node that evaluates a condition callable.
## Returns SUCCESS when the condition is true, FAILURE when false.
## Never returns RUNNING — condition checks are instantaneous.
##
## Usage:
##   var node := ConditionNode.new(func() -> bool: return blackboard["has_target"])


# ── State ──────────────────────────────────────────────────────────────────────

## The condition to evaluate. Must return bool and take no arguments.
var _condition: Callable


# ── Constructor ────────────────────────────────────────────────────────────────

## condition: a Callable that takes no arguments and returns bool.
func _init(condition: Callable) -> void:
	_condition = condition


# ── Tick ──────────────────────────────────────────────────────────────────────

func tick() -> int:
	return Status.SUCCESS if _condition.call() else Status.FAILURE
