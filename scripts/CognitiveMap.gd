class_name CognitiveMap
extends RefCounted

## Grid-based spatial map that an AI builds through raycasting as it explores.
## Uses Godot's AStarGrid2D for pathfinding through discovered walkable cells.
## All cells start as UNKNOWN (solid). Raycasts mark cells WALKABLE or BLOCKED.

# ── Cell States ──────────────────────────────────────────────────────────────

enum CellState { UNKNOWN, WALKABLE, BLOCKED }

# ── Grid Configuration ───────────────────────────────────────────────────────

## Grid region in cell coordinates (covers the full mansion + basement).
const GRID_REGION := Rect2i(-160, -130, 250, 200)
## World-space size of each grid cell (metres).
const CELL_SIZE := Vector2(1.0, 1.0)

# ── Internal State ───────────────────────────────────────────────────────────

var _grid: AStarGrid2D
## Per-cell state: Vector2i -> CellState.  UNKNOWN cells are simply absent.
var _cell_states: Dictionary = {}
## Cells where a ramp / slope was detected (stair locations).
var _stair_cells: Array[Vector2i] = []
## When each cell was last visited: Vector2i -> float (Engine.get_process_frames can be used).
var _visit_times: Dictionary = {}
## Total walkable cells discovered (for debug stats).
var _walkable_count: int = 0


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _init() -> void:
	_grid = AStarGrid2D.new()
	_grid.region = GRID_REGION
	_grid.cell_size = CELL_SIZE
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.update()
	# Start every cell as solid (unknown / impassable).
	_grid.fill_solid_region(GRID_REGION, true)


# ── Coordinate Conversion ────────────────────────────────────────────────────

## Convert a world XZ position to a grid cell coordinate.
func world_to_cell(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(world_pos.x)),
		int(floor(world_pos.z))
	)


## Convert a grid cell coordinate back to a world XZ position (cell centre).
func cell_to_world(cell: Vector2i, y: float = 0.0) -> Vector3:
	return Vector3(float(cell.x) + 0.5, y, float(cell.y) + 0.5)


# ── Cell Marking ─────────────────────────────────────────────────────────────

## Mark a world position's cell as WALKABLE (pathable).
func mark_walkable(world_pos: Vector3) -> void:
	var cell := world_to_cell(world_pos)
	if not _is_in_region(cell):
		return
	if _cell_states.get(cell, CellState.UNKNOWN) == CellState.WALKABLE:
		return  # already known walkable
	_cell_states[cell] = CellState.WALKABLE
	_grid.set_point_solid(cell, false)
	_walkable_count += 1


## Mark a world position's cell as BLOCKED (impassable wall / obstacle).
func mark_blocked(world_pos: Vector3) -> void:
	var cell := world_to_cell(world_pos)
	if not _is_in_region(cell):
		return
	if _cell_states.get(cell, CellState.UNKNOWN) == CellState.BLOCKED:
		return  # already known blocked
	# If a cell was previously walkable, decrement counter and re-solid.
	if _cell_states.get(cell, CellState.UNKNOWN) == CellState.WALKABLE:
		_walkable_count -= 1
	_cell_states[cell] = CellState.BLOCKED
	_grid.set_point_solid(cell, true)


## Mark all cells along a ray from `from` to `to` as WALKABLE (Bresenham line).
## The endpoint cell itself is NOT marked — the caller decides if it's blocked.
func mark_ray_walkable(from: Vector3, to: Vector3) -> void:
	var c0 := world_to_cell(from)
	var c1 := world_to_cell(to)
	var cells := _bresenham_line(c0, c1)
	# Mark every cell except the last one (hit point) as walkable.
	for i in range(cells.size() - 1):
		var cell: Vector2i = cells[i]
		if _is_in_region(cell):
			if _cell_states.get(cell, CellState.UNKNOWN) != CellState.WALKABLE:
				_cell_states[cell] = CellState.WALKABLE
				_grid.set_point_solid(cell, false)
				_walkable_count += 1


## Record that a slope / stair was detected at this world position.
func mark_stair(world_pos: Vector3) -> void:
	var cell := world_to_cell(world_pos)
	if cell not in _stair_cells:
		_stair_cells.append(cell)
		# Ensure stair cells are walkable.
		mark_walkable(world_pos)


## Update the visit timestamp for a cell.
func mark_visited(world_pos: Vector3, time: float) -> void:
	_visit_times[world_to_cell(world_pos)] = time


# ── Stair Queries ────────────────────────────────────────────────────────────

## Whether the AI has discovered any stair / ramp cells on this floor.
func has_discovered_stairs() -> bool:
	return _stair_cells.size() > 0


## Return the world position of the closest discovered stair cell to `from`.
func get_nearest_stair_entry(from: Vector3, y: float = 0.0) -> Vector3:
	if _stair_cells.is_empty():
		return Vector3.ZERO
	var from_cell := world_to_cell(from)
	var best_cell: Vector2i = _stair_cells[0]
	var best_dist: float = _cell_distance_sq(from_cell, best_cell)
	for i in range(1, _stair_cells.size()):
		var d: float = _cell_distance_sq(from_cell, _stair_cells[i])
		if d < best_dist:
			best_dist = d
			best_cell = _stair_cells[i]
	return cell_to_world(best_cell, y)


# ── Pathfinding ──────────────────────────────────────────────────────────────

## Find an A* path from one world position to another.
## Returns an array of world-space Vector2 (XZ) waypoints, or empty if no path.
func find_path(from: Vector3, to: Vector3) -> PackedVector2Array:
	var from_cell := world_to_cell(from)
	var to_cell   := world_to_cell(to)
	# Clamp to region bounds.
	from_cell = _clamp_to_region(from_cell)
	to_cell   = _clamp_to_region(to_cell)
	# Ensure start and end are walkable (AI is standing there / wants to go there).
	if _grid.is_point_solid(from_cell):
		_grid.set_point_solid(from_cell, false)
	# If the target cell is solid, find the nearest walkable cell to it.
	if _grid.is_point_solid(to_cell):
		to_cell = _find_nearest_walkable(to_cell)
		if to_cell == Vector2i(-99999, -99999):
			return PackedVector2Array()  # no reachable walkable cell near target
	var id_path: PackedVector2Array = _grid.get_point_path(from_cell, to_cell)
	# Convert from grid-cell centres to world XZ.
	var world_path := PackedVector2Array()
	for p in id_path:
		world_path.append(Vector2(p.x + 0.5, p.y + 0.5))
	return world_path


## Find the nearest WALKABLE cell that borders an UNKNOWN cell (exploration frontier).
## Uses BFS from `from`.  Returns Vector3.ZERO if none found.
func get_nearest_frontier(from: Vector3, current_time: float = 0.0) -> Vector3:
	var start := world_to_cell(from)
	start = _clamp_to_region(start)

	var visited_set: Dictionary = {}
	var queue: Array[Vector2i] = [start]
	visited_set[start] = true

	# Candidate frontiers: (cell, score).  Lower score = better.
	var best_cell := Vector2i(-99999, -99999)
	var best_score: float = INF

	var neighbors_4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var max_search := 3000  # cap BFS to avoid stalls

	while queue.size() > 0 and max_search > 0:
		max_search -= 1
		var cell: Vector2i = queue.pop_front()
		var state: int = _cell_states.get(cell, CellState.UNKNOWN)

		if state == CellState.WALKABLE:
			# Check if this walkable cell has an UNKNOWN neighbor → frontier.
			var is_frontier := false
			for offset in neighbors_4:
				var n: Vector2i = cell + offset
				if _is_in_region(n) and _cell_states.get(n, CellState.UNKNOWN) == CellState.UNKNOWN:
					is_frontier = true
					break

			if is_frontier:
				# Score: distance from start + recency penalty (prefer less-visited).
				var dist: float = _cell_distance_sq(start, cell)
				var last_visit: float = _visit_times.get(cell, 0.0)
				var recency: float = maxf(0.0, 30.0 - (current_time - last_visit))
				var score: float = dist + recency * 10.0
				if score < best_score:
					best_score = score
					best_cell = cell

		# Expand BFS through walkable cells only.
		if state == CellState.WALKABLE:
			for offset in neighbors_4:
				var n: Vector2i = cell + offset
				if _is_in_region(n) and not visited_set.has(n):
					visited_set[n] = true
					queue.append(n)

	if best_cell == Vector2i(-99999, -99999):
		return Vector3.ZERO
	return cell_to_world(best_cell)


## Find a frontier cell biased toward a target direction.
## Used when pathfinding fails — the AI explores toward the target
## instead of just toward the nearest unknown.
func get_frontier_toward(from: Vector3, toward: Vector3, current_time: float = 0.0) -> Vector3:
	var start := world_to_cell(from)
	start = _clamp_to_region(start)
	var goal := world_to_cell(toward)

	var visited_set: Dictionary = {}
	var queue: Array[Vector2i] = [start]
	visited_set[start] = true

	var best_cell := Vector2i(-99999, -99999)
	var best_score: float = INF

	var neighbors_4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var max_search := 3000

	while queue.size() > 0 and max_search > 0:
		max_search -= 1
		var cell: Vector2i = queue.pop_front()
		var state: int = _cell_states.get(cell, CellState.UNKNOWN)

		if state == CellState.WALKABLE:
			var is_frontier := false
			for offset in neighbors_4:
				var n: Vector2i = cell + offset
				if _is_in_region(n) and _cell_states.get(n, CellState.UNKNOWN) == CellState.UNKNOWN:
					is_frontier = true
					break
			if is_frontier:
				var dist_to_goal: float = _cell_distance_sq(cell, goal)
				var dist_from_start: float = _cell_distance_sq(start, cell)
				var last_visit: float = _visit_times.get(cell, 0.0)
				var recency: float = maxf(0.0, 30.0 - (current_time - last_visit))
				var score: float = dist_to_goal * 2.0 + dist_from_start * 0.5 + recency * 10.0
				if score < best_score:
					best_score = score
					best_cell = cell
			for offset in neighbors_4:
				var n: Vector2i = cell + offset
				if _is_in_region(n) and not visited_set.has(n):
					visited_set[n] = true
					queue.append(n)

	if best_cell == Vector2i(-99999, -99999):
		return Vector3.ZERO
	return cell_to_world(best_cell)


## Pick a random walkable cell (fallback when fully explored).
func get_random_walkable(from: Vector3) -> Vector3:
	var candidates: Array = []
	for cell in _cell_states:
		if _cell_states[cell] == CellState.WALKABLE:
			candidates.append(cell)
	if candidates.is_empty():
		return Vector3.ZERO
	# Pick one at random, biased away from the AI's current position.
	var from_cell := world_to_cell(from)
	var best_cell: Vector2i = candidates[randi() % candidates.size()]
	# Try a few random picks and take the one furthest from current pos.
	for _i in range(5):
		var c: Vector2i = candidates[randi() % candidates.size()]
		if _cell_distance_sq(from_cell, c) > _cell_distance_sq(from_cell, best_cell):
			best_cell = c
	return cell_to_world(best_cell)


# ── Queries ──────────────────────────────────────────────────────────────────

func is_cell_walkable(cell: Vector2i) -> bool:
	return _cell_states.get(cell, CellState.UNKNOWN) == CellState.WALKABLE


func get_walkable_count() -> int:
	return _walkable_count


func get_stair_count() -> int:
	return _stair_cells.size()


# ── Internal Helpers ─────────────────────────────────────────────────────────

func _is_in_region(cell: Vector2i) -> bool:
	return (cell.x >= GRID_REGION.position.x
		and cell.x < GRID_REGION.position.x + GRID_REGION.size.x
		and cell.y >= GRID_REGION.position.y
		and cell.y < GRID_REGION.position.y + GRID_REGION.size.y)


func _clamp_to_region(cell: Vector2i) -> Vector2i:
	return Vector2i(
		clampi(cell.x, GRID_REGION.position.x, GRID_REGION.position.x + GRID_REGION.size.x - 1),
		clampi(cell.y, GRID_REGION.position.y, GRID_REGION.position.y + GRID_REGION.size.y - 1)
	)


func _cell_distance_sq(a: Vector2i, b: Vector2i) -> float:
	var dx: float = float(a.x - b.x)
	var dy: float = float(a.y - b.y)
	return dx * dx + dy * dy


## Bresenham's line algorithm: returns all cells from c0 to c1 inclusive.
func _bresenham_line(c0: Vector2i, c1: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var x0: int = c0.x;  var y0: int = c0.y
	var x1: int = c1.x;  var y1: int = c1.y
	var dx: int = absi(x1 - x0)
	var dy: int = -absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy

	while true:
		result.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var e2: int = 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return result


## Find the nearest walkable cell to a target cell (BFS outward, small radius).
func _find_nearest_walkable(target: Vector2i) -> Vector2i:
	var visited_set: Dictionary = {}
	var queue: Array[Vector2i] = [target]
	visited_set[target] = true
	var neighbors: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var max_search := 500

	while queue.size() > 0 and max_search > 0:
		max_search -= 1
		var cell: Vector2i = queue.pop_front()
		if _is_in_region(cell) and not _grid.is_point_solid(cell):
			return cell
		for offset in neighbors:
			var n: Vector2i = cell + offset
			if not visited_set.has(n):
				visited_set[n] = true
				queue.append(n)

	return Vector2i(-99999, -99999)  # sentinel: no walkable cell found
