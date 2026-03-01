class_name BaseNode
extends RefCounted

## ── BaseNode ──────────────────────────────────────────────────────────────────
##
## Abstract base class for all Behaviour Tree nodes.
## Subclasses must override tick() and return a Status value.
##
## Usage:
##   var node := MyNode.new(...)
##   var result: int = node.tick()  # returns one of BaseNode.Status


# ── Status Enum ───────────────────────────────────────────────────────────────

enum Status {
	SUCCESS = 0,  ## Node completed successfully; parent Sequence continues
	FAILURE = 1,  ## Node failed; parent Selector tries next child
	RUNNING = 2,  ## Node is mid-execution; tree re-evaluates this branch next tick
}


# ── Virtual Interface ─────────────────────────────────────────────────────────

## Override in every subclass. Must return a Status value.
func tick() -> int:
	push_error(
		"BaseNode.tick() called on base class — override in subclass. Class: %s" % get_class()
	)
	return Status.FAILURE
