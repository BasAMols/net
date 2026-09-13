class_name HexNetGenerator
extends RefCounted

## Generates solved hex Net puzzles from a typed layout configuration.
##
## The generator is stateful while generate() is running and should not be used
## concurrently from multiple threads. A result owns all data needed after the
## call completes, including its wrapped or open neighbor topology.


enum Layout {
	SPIRAL,
	HEXAGON,
	RECTANGLE,
}

enum RectangleMode {
	AXIAL_PARALLELOGRAM,
	OFFSET_RECTANGLE,
}

enum Orientation {
	FLAT_TOP,
	POINTY_TOP,
}

enum OffsetParity {
	ODD,
	EVEN,
}


class GenerationParameters:
	var layout: int = Layout.HEXAGON
	var rectangle_mode: int = RectangleMode.OFFSET_RECTANGLE
	var orientation: int = Orientation.FLAT_TOP
	var offset_parity: int = OffsetParity.ODD

	# SPIRAL includes axial_from_index(0) through this index, inclusively.
	var max_spiral_index: int = 18

	# HEXAGON radius: 1 produces 7 cells, 2 produces 19, and so on.
	var radius: int = 2

	# RECTANGLE dimensions are measured in cells, not pixels.
	var width: int = 8
	var height: int = 8

	# SPIRAL/HEXAGON use wraparound. RECTANGLE uses the independent axes.
	var wraparound: bool = false
	var wrap_width: bool = false
	var wrap_height: bool = false

	var require_unique: bool = true
	var customSeed: int = -1
	var max_attempts: int = 2000


class GenerationResult:
	# Each entry contains axialCoord, asset_key, and solved rotation.
	var tiles: Array[Dictionary] = []
	var total_tiles: int = 0

	# Polygon-inclusive bounds with hex side length/circumradius == 1.0.
	var bounds: Rect2 = Rect2()

	# neighbors[tile_index][direction] is another tile index, or -1 for a
	# genuine boundary. Wrapped seams therefore need no coordinate guesswork.
	var neighbors: Array[PackedInt32Array] = []
	var coordinate_to_index: Dictionary[Vector2i, int] = {}

	var layout: int = Layout.HEXAGON
	var rectangle_mode: int = RectangleMode.OFFSET_RECTANGLE
	var orientation: int = Orientation.FLAT_TOP
	var offset_parity: int = OffsetParity.ODD
	var max_spiral_index: int = -1
	var radius: int = -1
	var width: int = 0
	var height: int = 0
	var wraparound: bool = false
	var wrap_width: bool = false
	var wrap_height: bool = false

	# Add this before rotation * 60.0 when using the original flat-top assets.
	var tile_rotation_offset_degrees: float = 0.0

	var require_unique: bool = true
	var unique_solution_verified: bool = false
	var solution_count: int = -1
	var customSeed: int = 0
	var attempts: int = 0
	var error: String = ""

	func succeeded() -> bool:
		return error.is_empty()


# Axial direction order supplied by the game. With a flat-top projection this
# is clockwise from south. With a pointy-top projection it is clockwise from
# southeast. In both cases adding one rotates a connector clockwise by 60°.
static var DIRECTIONS: Array[Vector2i] = [
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(1, 0),
]

const SQRT_3 := 1.7320508075688772

# These masks exactly mirror SOURCES[asset_key][2] from the game. Bit d means
# that the unrotated tile has an exit in DIRECTIONS[d].
const SHAPE_KEYS: Array[StringName] = [
	&"target",
	&"2_corner",
	&"2_hairpin",
	&"2_line",
	&"3_branch",
	&"3_branch_alt",
	&"3_even",
	&"3_side",
	&"4_branch",
	&"4_even",
	&"4_side",
	&"5",
	&"6",
]

const BASE_MASKS: Dictionary[StringName, int] = {
	&"target": (1 << 0),
	&"2_corner": (1 << 0) | (1 << 2),
	&"2_hairpin": (1 << 0) | (1 << 1),
	&"2_line": (1 << 0) | (1 << 3),
	&"3_branch": (1 << 0) | (1 << 2) | (1 << 3),
	&"3_branch_alt": (1 << 0) | (1 << 3) | (1 << 4),
	&"3_even": (1 << 0) | (1 << 2) | (1 << 4),
	&"3_side": (1 << 0) | (1 << 1) | (1 << 5),
	&"4_branch": (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5),
	&"4_even": (1 << 0) | (1 << 2) | (1 << 3) | (1 << 5),
	&"4_side": (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3),
	&"5": (1 << 0) | (1 << 1) | (1 << 2) | (1 << 4) | (1 << 5),
	&"6": 0b111111,
}

var _rng := RandomNumberGenerator.new()
var _cells: Array[Vector2i] = []
var _index_by_coord: Dictionary[Vector2i, int] = {}
var _neighbors_by_direction: Array[PackedInt32Array] = []
var _edges: Array[Vector3i] = []
var _hex_radius: int = -1


## Builds the requested layout, generates a spanning tree on its topology, and
## optionally rejects candidates until exactly one solution remains.
func generate(parameters: GenerationParameters) -> GenerationResult:
	var result := GenerationResult.new()
	if parameters == null:
		return _fail(result, "GenerationParameters cannot be null.")

	_copy_parameter_metadata(parameters, result)
	var validation_error := _validate_parameters(parameters)
	if not validation_error.is_empty():
		return _fail(result, validation_error)

	if parameters.customSeed >= 0:
		_rng.seed = parameters.customSeed
	else:
		_rng.randomize()
	result.customSeed = _rng.seed

	var layout_error := _build_layout(parameters)
	if not layout_error.is_empty():
		return _fail(result, layout_error)

	var topology_error := _build_topology(parameters)
	if not topology_error.is_empty():
		return _fail(result, topology_error)

	var attempts_to_run := parameters.max_attempts if parameters.require_unique else 1
	for attempt in range(1, attempts_to_run + 1):
		result.attempts = attempt
		var solved_masks := _generate_random_spanning_tree()

		if parameters.require_unique:
			var count := _count_solutions(solved_masks, 2)
			if count != 1:
				continue
			result.unique_solution_verified = true
			result.solution_count = 1

		var tiles := _make_tiles(solved_masks)
		if tiles.is_empty():
			return _fail(result, "A generated connector mask had no matching asset shape.")

		result.tiles = tiles
		result.total_tiles = tiles.size()
		result.bounds = _calculate_unit_bounds(parameters.orientation)
		result.coordinate_to_index = _index_by_coord.duplicate()
		result.neighbors = _copy_neighbors()
		return result

	return _fail(
		result,
		"No unique puzzle found after %d attempts (seed %d)."
		% [parameters.max_attempts, result.customSeed]
	)


static func axial_from_index(d: int) -> Vector2i:
	if d <= 0:
		return Vector2i.ZERO

	var ring := 1
	var first_index := 1
	while d >= first_index + 6 * ring:
		first_index += 6 * ring
		ring += 1

	var offset := d - first_index
	var hex := Vector2i(ring, 0)
	var directions := [
		Vector2i(-1, 1),
		Vector2i(-1, 0),
		Vector2i(0, -1),
		Vector2i(1, -1),
		Vector2i(1, 0),
		Vector2i(0, 1),
	]
	
	@warning_ignore("integer_division")
	var side := offset / ring
	var step := offset % ring
	for i in range(side):
		hex += directions[i] * ring
	hex += directions[side] * step
	return hex


static func axial_to_unit(coord: Vector2i, orientation: int) -> Vector2:
	if orientation == Orientation.POINTY_TOP:
		return Vector2(
			SQRT_3 * (coord.x + coord.y * 0.5),
			1.5 * coord.y
		)
	return Vector2(
		1.5 * coord.x,
		SQRT_3 * (coord.y + coord.x * 0.5)
	)


func _copy_parameter_metadata(
	parameters: GenerationParameters,
	result: GenerationResult
) -> void:
	result.layout = parameters.layout
	result.rectangle_mode = parameters.rectangle_mode
	result.orientation = parameters.orientation
	result.offset_parity = parameters.offset_parity
	result.wraparound = parameters.wraparound
	result.wrap_width = parameters.wrap_width
	result.wrap_height = parameters.wrap_height
	result.require_unique = parameters.require_unique
	result.tile_rotation_offset_degrees = (
		-30.0 if parameters.orientation == Orientation.POINTY_TOP else 0.0
	)

	match parameters.layout:
		Layout.SPIRAL:
			result.max_spiral_index = parameters.max_spiral_index
			result.radius = _complete_spiral_radius(parameters.max_spiral_index)
		Layout.HEXAGON:
			result.max_spiral_index = 3 * parameters.radius * (parameters.radius + 1)
			result.radius = parameters.radius
		Layout.RECTANGLE:
			result.width = parameters.width
			result.height = parameters.height


func _validate_parameters(parameters: GenerationParameters) -> String:
	if parameters.max_attempts < 1:
		return "max_attempts must be at least 1."
	if parameters.orientation not in [Orientation.FLAT_TOP, Orientation.POINTY_TOP]:
		return "Unknown hex orientation."

	match parameters.layout:
		Layout.SPIRAL:
			if parameters.max_spiral_index < 1:
				return "SPIRAL requires max_spiral_index >= 1; no zero-exit tile exists."
			if parameters.wrap_width or parameters.wrap_height:
				return "SPIRAL uses wraparound, not wrap_width or wrap_height."
			if (
				parameters.wraparound
				and _complete_spiral_radius(parameters.max_spiral_index) < 1
			):
				return "A wrapped SPIRAL must end on a complete ring."

		Layout.HEXAGON:
			if parameters.radius < 1:
				return "HEXAGON requires radius >= 1; no zero-exit tile exists."
			if parameters.wrap_width or parameters.wrap_height:
				return "HEXAGON uses wraparound, not wrap_width or wrap_height."

		Layout.RECTANGLE:
			if parameters.wraparound:
				return "RECTANGLE uses wrap_width and wrap_height, not wraparound."
			if parameters.width < 1 or parameters.height < 1:
				return "RECTANGLE width and height must both be at least 1."
			if parameters.width * parameters.height < 2:
				return "RECTANGLE must contain at least two cells; no zero-exit tile exists."
			if parameters.rectangle_mode not in [
				RectangleMode.AXIAL_PARALLELOGRAM,
				RectangleMode.OFFSET_RECTANGLE,
			]:
				return "Unknown rectangle mode."
			if parameters.offset_parity not in [OffsetParity.ODD, OffsetParity.EVEN]:
				return "Unknown offset parity."
			if parameters.wrap_width and parameters.width < 3:
				return "A wrapped rectangle width must be at least 3."
			if parameters.wrap_height and parameters.height < 3:
				return "A wrapped rectangle height must be at least 3."
			if parameters.rectangle_mode == RectangleMode.OFFSET_RECTANGLE:
				if (
					parameters.orientation == Orientation.FLAT_TOP
					and parameters.wrap_width
					and parameters.width % 2 != 0
				):
					return "Flat-top offset rectangles need an even width when wrapping width."
				if (
					parameters.orientation == Orientation.POINTY_TOP
					and parameters.wrap_height
					and parameters.height % 2 != 0
				):
					return "Pointy-top offset rectangles need an even height when wrapping height."

		_:
			return "Unknown layout type."

	return ""


func _build_layout(parameters: GenerationParameters) -> String:
	_cells.clear()
	_index_by_coord.clear()
	_hex_radius = -1

	match parameters.layout:
		Layout.SPIRAL:
			for spiral_index in range(parameters.max_spiral_index + 1):
				_cells.append(axial_from_index(spiral_index))
			if parameters.wraparound:
				_hex_radius = _complete_spiral_radius(parameters.max_spiral_index)

		Layout.HEXAGON:
			_hex_radius = parameters.radius
			var last_index := 3 * parameters.radius * (parameters.radius + 1)
			for spiral_index in range(last_index + 1):
				_cells.append(axial_from_index(spiral_index))

		Layout.RECTANGLE:
			for row in range(parameters.height):
				for column in range(parameters.width):
					if parameters.rectangle_mode == RectangleMode.AXIAL_PARALLELOGRAM:
						_cells.append(Vector2i(column, row))
					else:
						_cells.append(_offset_to_axial(
							Vector2i(column, row),
							parameters.orientation,
							parameters.offset_parity
						))

	for cell_index in range(_cells.size()):
		var coord := _cells[cell_index]
		if _index_by_coord.has(coord):
			return "Layout produced duplicate axial coordinate %s." % coord
		_index_by_coord[coord] = cell_index

	return ""


func _build_topology(parameters: GenerationParameters) -> String:
	_neighbors_by_direction.clear()
	_edges.clear()

	for cell_index in range(_cells.size()):
		var neighbors := PackedInt32Array([-1, -1, -1, -1, -1, -1])
		for direction in range(6):
			var raw_neighbor := _cells[cell_index] + DIRECTIONS[direction]
			var neighbor_index := -1

			if _index_by_coord.has(raw_neighbor):
				neighbor_index = int(_index_by_coord[raw_neighbor])
			elif parameters.layout == Layout.RECTANGLE:
				neighbor_index = _wrapped_rectangle_neighbor(raw_neighbor, parameters)
			elif parameters.wraparound:
				var wrapped_coord := _wrap_centered_hex_coord(raw_neighbor, _hex_radius)
				if _index_by_coord.has(wrapped_coord):
					neighbor_index = int(_index_by_coord[wrapped_coord])

			neighbors[direction] = neighbor_index
		_neighbors_by_direction.append(neighbors)

	var topology_error := _validate_topology()
	if not topology_error.is_empty():
		return topology_error

	for cell_index in range(_cells.size()):
		var neighbors: PackedInt32Array = _neighbors_by_direction[cell_index]
		for direction in range(6):
			var neighbor_index := neighbors[direction]
			if neighbor_index != -1 and cell_index < neighbor_index:
				_edges.append(Vector3i(cell_index, neighbor_index, direction))

	return ""


func _wrapped_rectangle_neighbor(
	raw_axial: Vector2i,
	parameters: GenerationParameters
) -> int:
	var grid_position := raw_axial
	if parameters.rectangle_mode == RectangleMode.OFFSET_RECTANGLE:
		grid_position = _axial_to_offset(
			raw_axial,
			parameters.orientation,
			parameters.offset_parity
		)

	if grid_position.x < 0 or grid_position.x >= parameters.width:
		if not parameters.wrap_width:
			return -1
		grid_position.x = posmod(grid_position.x, parameters.width)

	if grid_position.y < 0 or grid_position.y >= parameters.height:
		if not parameters.wrap_height:
			return -1
		grid_position.y = posmod(grid_position.y, parameters.height)

	var wrapped_axial := grid_position
	if parameters.rectangle_mode == RectangleMode.OFFSET_RECTANGLE:
		wrapped_axial = _offset_to_axial(
			grid_position,
			parameters.orientation,
			parameters.offset_parity
		)

	return int(_index_by_coord.get(wrapped_axial, -1))


func _wrap_centered_hex_coord(coord: Vector2i, radius: int) -> Vector2i:
	var translation_u := Vector2i(radius + 1, radius)
	var translation_v := Vector2i(-radius, 2 * radius + 1)

	# A direct neighbor can cross at most one seam, but the small wider search is
	# inexpensive and makes the canonicalization robust at wrapped corners.
	for u_multiple in range(-2, 3):
		for v_multiple in range(-2, 3):
			var candidate := (
				coord
				+ translation_u * u_multiple
				+ translation_v * v_multiple
			)
			if _index_by_coord.has(candidate):
				return candidate

	return coord


func _validate_topology() -> String:
	for cell_index in range(_neighbors_by_direction.size()):
		var neighbors: PackedInt32Array = _neighbors_by_direction[cell_index]
		var seen_neighbors: Dictionary = {}

		for direction in range(6):
			var neighbor_index := neighbors[direction]
			if neighbor_index == -1:
				continue
			if neighbor_index < 0 or neighbor_index >= _cells.size():
				return "Topology contains an invalid neighbor index."
			if neighbor_index == cell_index:
				return "Topology contains a self-neighbor at %s." % _cells[cell_index]
			if seen_neighbors.has(neighbor_index):
				return "Two directions from %s lead to the same tile." % _cells[cell_index]
			seen_neighbors[neighbor_index] = true

			var reverse_neighbors: PackedInt32Array = _neighbors_by_direction[neighbor_index]
			if reverse_neighbors[opposite_direction(direction)] != cell_index:
				return "Topology contains a non-reciprocal neighbor connection."

	var reached: Array[bool] = []
	reached.resize(_cells.size())
	reached.fill(false)
	reached[0] = true
	var queue: Array[int] = [0]
	var head := 0

	while head < queue.size():
		var cell_index := queue[head]
		head += 1
		var neighbors: PackedInt32Array = _neighbors_by_direction[cell_index]
		for neighbor_index in neighbors:
			if neighbor_index != -1 and not reached[neighbor_index]:
				reached[neighbor_index] = true
				queue.append(neighbor_index)

	for was_reached in reached:
		if not was_reached:
			return "Layout topology is disconnected."
	return ""


static func _offset_to_axial(
	offset_coord: Vector2i,
	orientation: int,
	parity: int
) -> Vector2i:
	var column := offset_coord.x
	var row := offset_coord.y

	if orientation == Orientation.FLAT_TOP:
		@warning_ignore("integer_division")
		var column_shift := (
			(column - (column & 1)) / 2
			if parity == OffsetParity.ODD
			else (column + (column & 1)) / 2
		)
		return Vector2i(column, row - column_shift)

	@warning_ignore("integer_division")
	var row_shift := (
		(row - (row & 1)) / 2
		if parity == OffsetParity.ODD
		else (row + (row & 1)) / 2
	)
	return Vector2i(column - row_shift, row)


static func _axial_to_offset(
	axial_coord: Vector2i,
	orientation: int,
	parity: int
) -> Vector2i:
	var q := axial_coord.x
	var r := axial_coord.y

	if orientation == Orientation.FLAT_TOP:
		@warning_ignore("integer_division")
		var column_shift := (
			(q - (q & 1)) / 2
			if parity == OffsetParity.ODD
			else (q + (q & 1)) / 2
		)
		return Vector2i(q, r + column_shift)

	@warning_ignore("integer_division")
	var row_shift := (
		(r - (r & 1)) / 2
		if parity == OffsetParity.ODD
		else (r + (r & 1)) / 2
	)
	return Vector2i(q + row_shift, r)


static func _complete_spiral_radius(max_spiral_index: int) -> int:
	var radius := 1
	while 3 * radius * (radius + 1) < max_spiral_index:
		radius += 1
	return radius if 3 * radius * (radius + 1) == max_spiral_index else -1


func _generate_random_spanning_tree() -> Array[int]:
	var cell_count := _cells.size()
	var masks: Array[int] = []
	masks.resize(cell_count)
	masks.fill(0)

	var visited: Array[bool] = []
	visited.resize(cell_count)
	visited.fill(false)

	var start := _rng.randi_range(0, cell_count - 1)
	visited[start] = true
	var visited_count := 1
	var frontier: Array[Vector3i] = []
	_add_frontier_edges(start, visited, frontier)

	while visited_count < cell_count:
		var frontier_index := _rng.randi_range(0, frontier.size() - 1)
		var edge := frontier[frontier_index]
		frontier[frontier_index] = frontier[-1]
		frontier.pop_back()

		if visited[edge.y]:
			continue

		masks[edge.x] |= 1 << edge.z
		masks[edge.y] |= 1 << opposite_direction(edge.z)
		visited[edge.y] = true
		visited_count += 1
		_add_frontier_edges(edge.y, visited, frontier)

	return masks


func _add_frontier_edges(
	cell_index: int,
	visited: Array[bool],
	frontier: Array[Vector3i]
) -> void:
	var neighbors: PackedInt32Array = _neighbors_by_direction[cell_index]
	for direction in range(6):
		var neighbor_index := neighbors[direction]
		if neighbor_index != -1 and not visited[neighbor_index]:
			frontier.append(Vector3i(cell_index, neighbor_index, direction))


func _count_solutions(solved_masks: Array[int], limit: int) -> int:
	var domains: Array = []
	for cell_index in range(_cells.size()):
		var domain: Array[int] = []
		for rotated_mask in _unique_rotations(solved_masks[cell_index]):
			if _mask_stays_on_board(cell_index, rotated_mask):
				domain.append(rotated_mask)
		if domain.is_empty():
			return 0
		domains.append(domain)
	return _search_solutions(domains, limit)


func _search_solutions(domains: Array, limit: int) -> int:
	if not _propagate(domains):
		return 0
	if not _possible_connection_graph_is_connected(domains):
		return 0
	if _forced_connections_have_cycle(domains):
		return 0

	var branch_cell := -1
	var smallest_domain := 7
	for cell_index in range(domains.size()):
		var domain_size: int = domains[cell_index].size()
		if domain_size > 1 and domain_size < smallest_domain:
			smallest_domain = domain_size
			branch_cell = cell_index

	if branch_cell == -1:
		return 1

	var solution_count := 0
	for orientation_mask in domains[branch_cell]:
		var branch_domains: Array = domains.duplicate(true)
		branch_domains[branch_cell] = [orientation_mask]
		solution_count += _search_solutions(
			branch_domains,
			limit - solution_count
		)
		if solution_count >= limit:
			return solution_count
	return solution_count


func _propagate(domains: Array) -> bool:
	var changed := true
	while changed:
		changed = false
		for edge in _edges:
			var result_a := _revise_domain(
				domains,
				edge.x,
				edge.y,
				edge.z,
				opposite_direction(edge.z)
			)
			if result_a < 0:
				return false
			changed = changed or result_a > 0

			var result_b := _revise_domain(
				domains,
				edge.y,
				edge.x,
				opposite_direction(edge.z),
				edge.z
			)
			if result_b < 0:
				return false
			changed = changed or result_b > 0
	return true


func _revise_domain(
	domains: Array,
	cell_index: int,
	neighbor_index: int,
	direction: int,
	neighbor_direction: int
) -> int:
	var supports_disconnected := false
	var supports_connected := false
	for neighbor_mask in domains[neighbor_index]:
		if _has_exit(neighbor_mask, neighbor_direction):
			supports_connected = true
		else:
			supports_disconnected = true

	var old_domain: Array = domains[cell_index]
	var revised: Array[int] = []
	for mask in old_domain:
		var connects := _has_exit(mask, direction)
		if (connects and supports_connected) or (
			not connects and supports_disconnected
		):
			revised.append(mask)

	if revised.is_empty():
		return -1
	if revised.size() == old_domain.size():
		return 0
	domains[cell_index] = revised
	return 1


func _possible_connection_graph_is_connected(domains: Array) -> bool:
	var reached: Array[bool] = []
	reached.resize(_cells.size())
	reached.fill(false)
	reached[0] = true

	var queue: Array[int] = [0]
	var head := 0
	while head < queue.size():
		var cell_index := queue[head]
		head += 1
		var neighbors: PackedInt32Array = _neighbors_by_direction[cell_index]

		for direction in range(6):
			var neighbor_index := neighbors[direction]
			if neighbor_index == -1 or reached[neighbor_index]:
				continue
			if (
				_domain_can_connect(domains[cell_index], direction)
				and _domain_can_connect(
					domains[neighbor_index],
					opposite_direction(direction)
				)
			):
				reached[neighbor_index] = true
				queue.append(neighbor_index)

	for was_reached in reached:
		if not was_reached:
			return false
	return true


func _forced_connections_have_cycle(domains: Array) -> bool:
	var parent := PackedInt32Array()
	var rank := PackedInt32Array()
	parent.resize(_cells.size())
	rank.resize(_cells.size())
	for index in range(_cells.size()):
		parent[index] = index

	for edge in _edges:
		if not _domain_must_connect(domains[edge.x], edge.z):
			continue
		if not _domain_must_connect(
			domains[edge.y],
			opposite_direction(edge.z)
		):
			continue

		var root_a := _dsu_find(parent, edge.x)
		var root_b := _dsu_find(parent, edge.y)
		if root_a == root_b:
			return true
		if rank[root_a] < rank[root_b]:
			parent[root_a] = root_b
		elif rank[root_a] > rank[root_b]:
			parent[root_b] = root_a
		else:
			parent[root_b] = root_a
			rank[root_a] += 1
	return false


static func _dsu_find(parent: PackedInt32Array, node: int) -> int:
	var root := node
	while parent[root] != root:
		root = parent[root]
	while parent[node] != node:
		var next := parent[node]
		parent[node] = root
		node = next
	return root


func _make_tiles(solved_masks: Array[int]) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	output.resize(_cells.size())
	for cell_index in range(_cells.size()):
		var shape := _classify_mask(solved_masks[cell_index])
		if shape.is_empty():
			return []
		output[cell_index] = {
			"axialCoord": _cells[cell_index],
			"asset_key": shape["asset_key"],
			"rotation": shape["rotation"],
		}
	return output


func _classify_mask(mask: int) -> Dictionary:
	for asset_key in SHAPE_KEYS:
		var base_mask: int = BASE_MASKS[asset_key]
		for rotation in range(6):
			if rotate_mask(base_mask, rotation) == mask:
				return {
					"asset_key": asset_key,
					"rotation": rotation,
				}
	return {}


func _calculate_unit_bounds(orientation: int) -> Rect2:
	var first_center := axial_to_unit(_cells[0], orientation)
	var half_extents := (
		Vector2(SQRT_3 * 0.5, 1.0)
		if orientation == Orientation.POINTY_TOP
		else Vector2(1.0, SQRT_3 * 0.5)
	)
	var minimum := first_center - half_extents
	var maximum := first_center + half_extents

	for cell_index in range(1, _cells.size()):
		var center := axial_to_unit(_cells[cell_index], orientation)
		minimum = minimum.min(center - half_extents)
		maximum = maximum.max(center + half_extents)
	return Rect2(minimum, maximum - minimum)


func _copy_neighbors() -> Array[PackedInt32Array]:
	var copied: Array[PackedInt32Array] = []
	for neighbors in _neighbors_by_direction:
		copied.append(PackedInt32Array(neighbors))
	return copied


func _mask_stays_on_board(cell_index: int, mask: int) -> bool:
	var neighbors: PackedInt32Array = _neighbors_by_direction[cell_index]
	for direction in range(6):
		if neighbors[direction] == -1 and _has_exit(mask, direction):
			return false
	return true


static func _unique_rotations(mask: int) -> Array[int]:
	var result: Array[int] = []
	for rotation in range(6):
		var rotated := rotate_mask(mask, rotation)
		if not result.has(rotated):
			result.append(rotated)
	return result


static func rotate_mask(mask: int, rotation: int) -> int:
	var normalized := posmod(rotation, 6)
	if normalized == 0:
		return mask & 0b111111
	return (
		((mask << normalized) | (mask >> (6 - normalized)))
		& 0b111111
	)


static func opposite_direction(direction: int) -> int:
	return (direction + 3) % 6


static func _has_exit(mask: int, direction: int) -> bool:
	return (mask & (1 << direction)) != 0


static func _domain_can_connect(domain: Array, direction: int) -> bool:
	for mask in domain:
		if _has_exit(mask, direction):
			return true
	return false


static func _domain_must_connect(domain: Array, direction: int) -> bool:
	for mask in domain:
		if not _has_exit(mask, direction):
			return false
	return true


func _fail(result: GenerationResult, message: String) -> GenerationResult:
	result.error = message
	push_error(message)
	return result
