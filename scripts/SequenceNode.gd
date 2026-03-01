class_name SequenceNode
extends BaseNode

## ── SequenceNode ──────────────────────────────────────────────────────────────
##
## Composite node — logical AND.
## Runs each child in order.
## Returns the first FAILURE or RUNNING result.
## Returns SUCCESS only if every child succeeds.
##
## Usage (as a behaviour branch requiring all conditions and actions to pass):
##   var hunt := SequenceNode.new([cond_in_range, action_update_los, action_move])


# ── State ──────────────────────────────────────────────────────────────────────

## Child nodes evaluated in order. Each element must extend BaseNode.
var _children: Array  # Array[BaseNode]


# ── Constructor ────────────────────────────────────────────────────────────────

## children: Array of BaseNode instances in execution order.
func _init(children: Array) -> void:
	_children = children


# ── Tick ──────────────────────────────────────────────────────────────────────

func tick() -> int:
	for child: BaseNode in _children:
		var result: int = child.tick()
		if result != Status.SUCCESS:
			# FAILURE stops the sequence; RUNNING pauses it until next tick
			return result
	return Status.SUCCESS
