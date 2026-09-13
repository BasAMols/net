class_name HexGrid
extends Control

@export var tile: PackedScene
@export var tileScript: Script
@export var repeat_layer: Parallax2D
@export var repeat_content: Node2D
@export var camera: PlayfieldCamera

signal completed
signal newPuzzle
signal autoSolve
signal validated(isDone: bool)

var rng = RandomNumberGenerator.new()
var puzzle: Array[Dictionary]
var tiles: Dictionary[Vector2i, Tile] = {}
var spawns: Dictionary[Vector2i, Tile] = {}
var generator: HexNetGenerator
var parameters: HexNetGenerator.GenerationParameters
var result: HexNetGenerator.GenerationResult

var repeat_u_axial := Vector2i.ZERO
var repeat_v_axial := Vector2i.ZERO
var repeat_u_world := Vector2.ZERO
var repeat_v_world := Vector2.ZERO
var repeat_origin_world := Vector2.ZERO
var repeat_axes := Vector2.ZERO
var repeat_available := false
var repeat_visible := false
var _visual_settings_signature := -1

var tileSize: int = 200
var count: int
var tileCount: int
var isDone: bool
var hasBeenDone: bool = false

func setSpawn(newTile: Tile) -> void: 
	for t in spawns.values():
		t.set_spawn_state(false)
	
	spawns = {newTile.axialCoord: newTile}
	newTile.set_spawn_state(true)
	validate()

func _ready() -> void:
	generator = HexNetGenerator.new()
	camera.get_viewport().size_changed.connect(_on_viewport_size_changed)
	new_puzzle()
	_visual_settings_signature = _get_visual_settings_signature()

func _process(_delta: float) -> void:
	if repeat_available:
		var should_show_repeats := SettingsStore.get_bool(SettingsStore.SHOW_GHOST)
		if should_show_repeats != repeat_visible:
			_set_repeat_visuals_enabled(should_show_repeats)

	var settings_signature := _get_visual_settings_signature()
	if settings_signature != _visual_settings_signature:
		_visual_settings_signature = settings_signature
		_mark_all_tiles_visual_dirty()


func _get_visual_settings_signature() -> int:
	var signature := 0
	if SettingsStore.get_bool(SettingsStore.SHOW_PATHS):
		signature |= 1 << 0
	if SettingsStore.get_bool(SettingsStore.SHOW_LOOP_ERRORS):
		signature |= 1 << 1
	if SettingsStore.get_bool(SettingsStore.SHOW_ISOLATION_ERRORS):
		signature |= 1 << 2
	if SettingsStore.get_bool(SettingsStore.COMPLETION_EFFECT):
		signature |= 1 << 3
	if SettingsStore.get_bool(SettingsStore.RAINBOW_PATHS):
		signature |= 1 << 4
	if SettingsStore.get_bool(SettingsStore.REVIEW_LOCKED):
		signature |= 1 << 5
	if SettingsStore.get_bool(SettingsStore.REVIEW_UNLOCKED):
		signature |= 1 << 6
	return signature


func _mark_all_tiles_visual_dirty() -> void:
	for t: Tile in tiles.values():
		t.mark_visual_dirty()


func _frame_board(
	reset_view: bool = false,
	margin_pixels: float = 40.0
) -> Rect2:
	if result == null or result.bounds.size == Vector2.ZERO:
		return Rect2()
	var bounds: Rect2 = result.bounds
	var world_bounds := Rect2(
		bounds.position * tileSize,
		bounds.size * tileSize
	)
	camera.configure_bounds(world_bounds, reset_view, margin_pixels)
	_update_repeat_coverage()
	return world_bounds


func _on_viewport_size_changed() -> void:
	_frame_board(false)


func _configure_repetition() -> void:
	repeat_u_axial = Vector2i.ZERO
	repeat_v_axial = Vector2i.ZERO
	repeat_axes = Vector2.ZERO
	repeat_available = false

	match result.layout:
		HexNetGenerator.Layout.SPIRAL, HexNetGenerator.Layout.HEXAGON:
			if result.wraparound:
				var radius := result.radius
				repeat_u_axial = Vector2i(radius + 1, radius)
				repeat_v_axial = Vector2i(-radius, 2 * radius + 1)
				repeat_axes = Vector2.ONE

		HexNetGenerator.Layout.RECTANGLE:
			if result.rectangle_mode == HexNetGenerator.RectangleMode.AXIAL_PARALLELOGRAM:
				repeat_u_axial = Vector2i(maxi(result.width, 1), 0)
				repeat_v_axial = Vector2i(0, maxi(result.height, 1))
			elif result.orientation == HexNetGenerator.Orientation.FLAT_TOP:
				repeat_u_axial = Vector2i(
					maxi(result.width, 1),
					-int(result.width / 2)
				)
				repeat_v_axial = Vector2i(0, maxi(result.height, 1))
			else:
				repeat_u_axial = Vector2i(maxi(result.width, 1), 0)
				repeat_v_axial = Vector2i(
					-int(result.height / 2),
					maxi(result.height, 1)
				)

			repeat_axes = Vector2(
				1.0 if result.wrap_width else 0.0,
				1.0 if result.wrap_height else 0.0
			)

	if repeat_axes == Vector2.ZERO:
		repeat_layer.repeat_size = Vector2.ZERO
		repeat_layer.transform = Transform2D.IDENTITY
		repeat_content.transform = Transform2D.IDENTITY
		repeat_visible = false

		return

	repeat_u_world = (
		HexNetGenerator.axial_to_unit(repeat_u_axial, result.orientation)
		* tileSize
	)
	repeat_v_world = (
		HexNetGenerator.axial_to_unit(repeat_v_axial, result.orientation)
		* tileSize
	)

	var repeat_basis := Transform2D(
		repeat_u_world,
		repeat_v_world,
		Vector2.ZERO
	)
	if absf(repeat_basis.determinant()) < 0.001:
		push_error("The wrapped board produced a degenerate visual repeat basis.")
		return

	# Parallax2D repeats descendants along its local X/Y axes. Applying the
	# lattice basis to the repeat node and its inverse to the content leaves the
	# real board unchanged while its renderer-generated copies use the oblique
	# wrap translations. No Tile nodes are cloned.
	repeat_layer.ignore_camera_scroll = true
	repeat_layer.follow_viewport = false
	repeat_layer.repeat_size = Vector2.ZERO
	repeat_layer.transform = repeat_basis
	repeat_content.transform = repeat_basis.affine_inverse()
	repeat_available = true

	_set_repeat_visuals_enabled(SettingsStore.get_bool(SettingsStore.SHOW_GHOST))


func _set_repeat_visuals_enabled(enabled: bool) -> void:
	repeat_visible = repeat_available and enabled
	repeat_layer.repeat_size = repeat_axes if repeat_visible else Vector2.ZERO


func _update_repeat_coverage() -> void:
	if not repeat_available or camera.min_zoom <= 0.0:
		repeat_layer.repeat_times = 1
		return

	var half_view := (
		camera.get_viewport().get_visible_rect().size
		/ (camera.min_zoom * 2.0)
	)
	var corners := [
		Vector2(-half_view.x, -half_view.y),
		Vector2(half_view.x, -half_view.y),
		Vector2(half_view.x, half_view.y),
		Vector2(-half_view.x, half_view.y),
	]
	var maximum_coefficient := 0.0
	for corner: Vector2 in corners:
		var coefficient := _world_vector_to_lattice(corner)
		if repeat_axes.x > 0.0:
			maximum_coefficient = maxf(maximum_coefficient, absf(coefficient.x))
		if repeat_axes.y > 0.0:
			maximum_coefficient = maxf(maximum_coefficient, absf(coefficient.y))

	var repeat_radius := maxi(1, ceili(maximum_coefficient + 0.5))
	repeat_layer.repeat_times = repeat_radius * 2 + 1


func wrap_world_position(world_position: Vector2) -> Vector2:
	if not repeat_visible:
		return world_position

	var relative_position := world_position - repeat_origin_world
	var coefficient := _world_vector_to_lattice(relative_position)
	if repeat_axes.x > 0.0:
		relative_position -= repeat_u_world * roundf(coefficient.x)
	if repeat_axes.y > 0.0:
		relative_position -= repeat_v_world * roundf(coefficient.y)
	return repeat_origin_world + relative_position


func _world_vector_to_lattice(world_vector: Vector2) -> Vector2:
	var determinant := repeat_u_world.cross(repeat_v_world)
	if absf(determinant) < 0.001:
		return Vector2.ZERO
	return Vector2(
		world_vector.cross(repeat_v_world) / determinant,
		repeat_u_world.cross(world_vector) / determinant
	)


func tile_at_world_position(world_position: Vector2) -> Tile:
	if tiles.is_empty() or result == null:
		return null

	var local_position := get_global_transform().affine_inverse() * world_position
	var display_coord := _unit_to_axial(local_position / tileSize, result.orientation)
	if tiles.has(display_coord):
		return tiles[display_coord]
	if not repeat_visible:
		return null

	var search_radius := int(repeat_layer.repeat_times / 2) + 1
	var found_coord := Vector2i.ZERO
	var found := false
	for u_multiple in range(-search_radius, search_radius + 1):
		if repeat_axes.x == 0.0 and u_multiple != 0:
			continue
		for v_multiple in range(-search_radius, search_radius + 1):
			if repeat_axes.y == 0.0 and v_multiple != 0:
				continue
			var candidate := (
				display_coord
				- repeat_u_axial * u_multiple
				- repeat_v_axial * v_multiple
			)
			if not tiles.has(candidate):
				continue
			if found and candidate != found_coord:
				push_error(
					"Visual repeat coordinate %s maps to both %s and %s."
					% [display_coord, found_coord, candidate]
				)
				return null
			found = true
			found_coord = candidate

	return tiles[found_coord] if found else null


func _unit_to_axial(unit_position: Vector2, orientation: int) -> Vector2i:
	var q: float
	var r: float
	if orientation == HexNetGenerator.Orientation.POINTY_TOP:
		q = HexNetGenerator.SQRT_3 / 3.0 * unit_position.x - unit_position.y / 3.0
		r = 2.0 / 3.0 * unit_position.y
	else:
		q = 2.0 / 3.0 * unit_position.x
		r = -unit_position.x / 3.0 + HexNetGenerator.SQRT_3 / 3.0 * unit_position.y

	var x := q
	var z := r
	var y := -x - z
	var rounded_x := roundi(x)
	var rounded_y := roundi(y)
	var rounded_z := roundi(z)
	var x_difference := absf(rounded_x - x)
	var y_difference := absf(rounded_y - y)
	var z_difference := absf(rounded_z - z)

	if x_difference > y_difference and x_difference > z_difference:
		rounded_x = -rounded_y - rounded_z
	elif y_difference > z_difference:
		rounded_y = -rounded_x - rounded_z
	else:
		rounded_z = -rounded_x - rounded_y

	return Vector2i(rounded_x, rounded_z)

func tileChanged() ->void: 
	validate()

func solve(all = true) -> void:
	for t in tiles.values():
		if all or not t.lock:
			t.tileRotate(t.correct, false)
	
	validate()
	autoSolve.emit()

func rand(force: bool = false) -> void:
	for t in tiles.values():
		if !t.lock:
			t.randomRotate(false)
			if force: 
				t.force()

	validate()

func clear() -> void:
	for t in tiles.values():
		t.queue_free()

	tiles.clear()
	spawns.clear()
	puzzle.clear()
	result = null

func validate() -> void:
	if tiles.is_empty():
		return

	var visited: Dictionary[Vector2i, bool] = {}

	for start_coord: Vector2i in tiles:
		if visited.has(start_coord):
			continue

		var component: Array[Vector2i] = []
		var stack: Array[Vector2i] = [start_coord]

		var contains_spawn := false
		var is_closed := true

		# Each valid connection is counted from both ends.
		var connected_half_edges := 0

		while not stack.is_empty():
			var coord: Vector2i = stack.pop_back()

			if visited.has(coord):
				continue

			visited[coord] = true
			component.append(coord)

			if spawns.has(coord):
				contains_spawn = true

			var t: Tile = tiles[coord]

			for neighbor_coord: Vector2i in t.get_exit_neighbors():
				# Exit points outside a genuine board boundary.
				if not tiles.has(neighbor_coord):
					is_closed = false
					continue

				var neighbor: Tile = tiles[neighbor_coord]

				# The neighboring tile does not connect back.
				if not neighbor.has_exit_towards(coord):
					is_closed = false
					continue

				connected_half_edges += 1

				if not visited.has(neighbor_coord):
					stack.append(neighbor_coord)

		# For a connected undirected component:
		#   edges < vertices  -> no cycle
		#   edges >= vertices -> at least one cycle
		#
		# Each edge was counted twice, hence the multiplication by two.
		var contains_loop := (
			connected_half_edges >= component.size() * 2
		)

		for coord: Vector2i in component:
			var t: Tile = tiles[coord]
			t.set_validation_state(contains_spawn, is_closed, contains_loop)

	
	count = tiles.values().filter(func (t): return t._match()).size()
	

	var was_done := isDone
	isDone = count == tileCount
	if isDone != was_done:
		_mark_all_tiles_visual_dirty()

	validated.emit(isDone)

	if isDone and not hasBeenDone:
		hasBeenDone = true
		completed.emit()

func new_puzzle() -> void:
	clear()
	hasBeenDone = false
	isDone = false

	parameters = _create_generation_parameters()

	result = generator.generate(parameters);
	if not result.succeeded() or result.tiles.is_empty():
		push_error(result.error)
		return

	puzzle = result.tiles
	tileCount = result.total_tiles
	_configure_repetition()
	_frame_board(true)

	for di in range(result.tiles.size()):
		var d = puzzle[di]
		var t = tile.instantiate() as Tile
		t.set_script(tileScript)
		t.setup(
			di,
			d.asset_key,
			d.axialCoord,
			di == 0,
			d.rotation,
			tileSize,
			result,
			self
		)

		tiles[d.axialCoord] = t
		
		if (di == 0):
			spawns[d.axialCoord] = t

		add_child(t)

	rand(true)
	newPuzzle.emit()


func _create_generation_parameters() -> HexNetGenerator.GenerationParameters:
	var new_parameters := HexNetGenerator.GenerationParameters.new()
	var layout := SettingsStore.get_int(SettingsStore.LAYOUT) + 1

	new_parameters.layout = layout
	new_parameters.rectangle_mode = HexNetGenerator.RectangleMode.OFFSET_RECTANGLE
	new_parameters.orientation = SettingsStore.get_int(SettingsStore.ORIENTATION)
	new_parameters.offset_parity = HexNetGenerator.OffsetParity.ODD
	new_parameters.require_unique = SettingsStore.get_bool(SettingsStore.UNIQUE_SOLUTION)

	match layout:
		HexNetGenerator.Layout.HEXAGON:
			new_parameters.wraparound = SettingsStore.get_bool(SettingsStore.WRAP)
			new_parameters.radius = SettingsStore.get_int(SettingsStore.RADIUS)
		HexNetGenerator.Layout.RECTANGLE:
			var wr := SettingsStore.get_bool(SettingsStore.WRAP)
			new_parameters.wrap_width = wr
			new_parameters.wrap_height = wr
			new_parameters.width = SettingsStore.get_int(SettingsStore.RECTANGLE_WIDTH)
			new_parameters.height = SettingsStore.get_int(SettingsStore.RECTANGLE_HEIGHT)

	return new_parameters
