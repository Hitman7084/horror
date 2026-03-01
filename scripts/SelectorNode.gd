class_name SelectorNode
extends BaseNode

## ── SelectorNode ──────────────────────────────────────────────────────────────
##
## Composite node — logical OR.
## Tries each child in order.
## Returns the first SUCCESS or RUNNING result.
## Returns FAILURE only if every child fails.
##
## Usage (as tree root with three priority branches):
##   var root := SelectorNode.new([hunt_seq, investigate_seq, explore_seq])


# ── State ──────────────────────────────────────────────────────────────────────

## Child nodes evaluated in order. Each element must extend BaseNode.
var _children: Array  # Array[BaseNode]


# ── Constructor ────────────────────────────────────────────────────────────────

## children: Array of BaseNode instances in priority order.
func _init(children: Array) -> void:
	_children = children


# ── Tick ──────────────────────────────────────────────────────────────────────

func tick() -> int:
	for child: BaseNode in _children:
		var result: int = child.tick()
		if result != Status.FAILURE:
			# First SUCCESS or RUNNING short-circuits; lower-priority branches skipped
			return result
	return Status.FAILURE
