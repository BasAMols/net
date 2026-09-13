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
signal undo_state_changed(can_undo: bool, can_redo: bool)

const PUZZLE_FORMAT := "hexnet-puzzle"
const PUZZLE_FORMAT_VERSION := 1
const AUTOSAVE_PATH := "user://puzzle_autosave.json"
const INVALID_AUTOSAVE_PATH := "user://puzzle_autosave.invalid.json"
const AUTOSAVE_DELAY_SECONDS := 0.35
const MAX_HISTORY_STEPS := 200
const MAX_IMPORT_BYTES := 2_000_000
const MAX_IMPORT_TILES := 2500

var rng := RandomNumberGenerator.new()
var puzzle: Array[Dictionary]
var tiles: Dictionary[Vector2i, Tile] = {}
var tile_states: Dictionary[Vector2i, Dictionary] = {}
var spawn_coord := Vector2i.ZERO
var has_spawn := false
var generator: HexNetGenerator
var parameters: HexNetGenerator.GenerationParameters
var result: HexNetGenerator.GenerationResult
var undo_redo := UndoRedo.new()

var _history_records: Array[Dictionary] = []
var _history_base_states: Dictionary[Vector2i, Dictionary] = {}
var _history_base_spawn := Vector2i.ZERO
var _history_base_has_spawn := false
var _autosave_timer: Timer
var _suppress_side_effects := false
var _last_import_error := ""

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

func _ready() -> void:
	generator = HexNetGenerator.new()
	rng.randomize()
	undo_redo.max_steps = MAX_HISTORY_STEPS
	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = true
	_autosave_timer.wait_time = AUTOSAVE_DELAY_SECONDS
	_autosave_timer.timeout.connect(save_puzzle_autosave)
	add_child(_autosave_timer)
	camera.get_viewport().size_changed.connect(_on_viewport_size_changed)
	var load_error := load_puzzle_autosave()
	if load_error != OK:
		new_puzzle()
	_visual_settings_signature = _get_visual_settings_signature()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_puzzle_autosave()


func _exit_tree() -> void:
	if not tiles.is_empty():
		save_puzzle_autosave()
	if is_instance_valid(undo_redo):
		undo_redo.free()

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
	if SettingsStore.get_bool(SettingsStore.DISABLE_ANIMATION):
		signature |= 1 << 7
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


func coordinate_at_world_position(world_position: Vector2) -> Variant:
	if tile_states.is_empty() or result == null:
		return null

	var local_position := get_global_transform().affine_inverse() * world_position
	var display_coord := _unit_to_axial(local_position / tileSize, result.orientation)
	if tile_states.has(display_coord):
		return display_coord
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
			if not tile_states.has(candidate):
				continue
			if found and candidate != found_coord:
				push_error(
					"Visual repeat coordinate %s maps to both %s and %s."
					% [display_coord, found_coord, candidate]
				)
				return null
			found = true
			found_coord = candidate

	return found_coord if found else null


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

func request_rotate_tile(coord: Vector2i, direction: int, move_source: bool = false) -> bool:
	if not tile_states.has(coord) or tile_states[coord]["locked"]:
		return false
	var before := _core_state(coord)
	var after := before.duplicate()
	after["rotation"] = posmod(int(before["rotation"]) + direction, 6)
	var record := _make_action_record("Rotate tile", coord, before, after)
	if move_source and (not has_spawn or spawn_coord != coord):
		record["spawn_before"] = spawn_coord if has_spawn else null
		record["spawn_after"] = coord
	return _commit_action_record(record)


func request_toggle_lock(coord: Vector2i) -> bool:
	if not tile_states.has(coord):
		return false
	var before := _core_state(coord)
	var after := before.duplicate()
	after["locked"] = not bool(before["locked"])
	return _commit_action_record(_make_action_record("Toggle tile lock", coord, before, after))


func request_set_spawn(coord: Vector2i) -> bool:
	if not tile_states.has(coord) or (has_spawn and spawn_coord == coord):
		return false
	return _commit_action_record({
		"name": "Move source",
		"changes": [],
		"spawn_before": spawn_coord if has_spawn else null,
		"spawn_after": coord,
	})


func solve(all: bool = true) -> void:
	var changes: Array[Dictionary] = []
	for coord: Vector2i in tile_states:
		var state: Dictionary = tile_states[coord]
		if not all and state["locked"]:
			continue
		var correct_rotation := _correct_rotation(coord)
		if state["rotation"] == correct_rotation:
			continue
		var before := _core_state(coord)
		var after := before.duplicate()
		after["rotation"] = correct_rotation
		changes.append({"coord": coord, "before": before, "after": after})

	if _commit_action_record({"name": "Solve puzzle", "changes": changes}):
		autoSolve.emit()


func rand() -> void:
	var changes: Array[Dictionary] = []
	for coord: Vector2i in tile_states:
		var state: Dictionary = tile_states[coord]
		if state["locked"]:
			continue
		var next_rotation := rng.randi_range(0, 5)
		if state["rotation"] == next_rotation:
			continue
		var before := _core_state(coord)
		var after := before.duplicate()
		after["rotation"] = next_rotation
		changes.append({"coord": coord, "before": before, "after": after})
	_commit_action_record({"name": "Randomise puzzle", "changes": changes})


func undo_puzzle_action() -> bool:
	if not undo_redo.undo():
		return false
	_queue_autosave()
	_emit_undo_state()
	return true


func redo_puzzle_action() -> bool:
	if not undo_redo.redo():
		return false
	_queue_autosave()
	_emit_undo_state()
	return true


func has_undo() -> bool:
	return undo_redo.has_undo()


func has_redo() -> bool:
	return undo_redo.has_redo()


func clear() -> void:
	for view: Tile in tiles.values():
		view.queue_free()
	tiles.clear()
	tile_states.clear()
	puzzle.clear()
	result = null
	has_spawn = false


func validate() -> void:
	if tile_states.is_empty() or result == null:
		return

	for coord: Vector2i in tile_states:
		var reset_state: Dictionary = tile_states[coord]
		reset_state["active"] = false
		reset_state["isolated"] = false
		reset_state["looped"] = false
		tile_states[coord] = reset_state

	var visited: Dictionary[Vector2i, bool] = {}
	for start_coord: Vector2i in tile_states:
		if visited.has(start_coord):
			continue

		var component: Array[Vector2i] = []
		var stack: Array[Vector2i] = [start_coord]
		var contains_spawn := false
		var is_closed := true
		var connected_half_edges := 0

		while not stack.is_empty():
			var coord: Vector2i = stack.pop_back()
			if visited.has(coord):
				continue
			visited[coord] = true
			component.append(coord)
			if has_spawn and coord == spawn_coord:
				contains_spawn = true

			for neighbor_coord: Vector2i in _get_exit_neighbors(coord):
				if not tile_states.has(neighbor_coord):
					is_closed = false
					continue
				if not _has_exit_towards(neighbor_coord, coord):
					is_closed = false
					continue
				connected_half_edges += 1
				if not visited.has(neighbor_coord):
					stack.append(neighbor_coord)

		var contains_loop := connected_half_edges >= component.size() * 2
		for coord: Vector2i in component:
			var state: Dictionary = tile_states[coord]
			state["active"] = contains_spawn
			state["isolated"] = is_closed
			state["looped"] = contains_loop
			tile_states[coord] = state

	count = 0
	for coord: Vector2i in tile_states:
		if _is_correct(coord):
			count += 1

	var was_done := isDone
	isDone = count == tileCount
	_sync_all_tile_views(false)
	if not _suppress_side_effects:
		validated.emit(isDone)
		if isDone and not hasBeenDone:
			hasBeenDone = true
			completed.emit()
	if isDone != was_done:
		_mark_all_tiles_visual_dirty()


func new_puzzle() -> void:
	parameters = _create_generation_parameters()
	var generated_result := generator.generate(parameters)
	if not generated_result.succeeded() or generated_result.tiles.is_empty():
		push_error(generated_result.error)
		return

	clear()
	result = generated_result
	puzzle = result.tiles
	tileCount = result.total_tiles
	hasBeenDone = false
	isDone = false
	_initialize_model_from_result()
	_randomize_states_direct()
	_instantiate_tile_views()
	_configure_repetition()
	_frame_board(true)
	validate()
	_sync_all_tile_views(true)
	_reset_history_to_current_state()
	_queue_autosave()
	newPuzzle.emit()


func _initialize_model_from_result() -> void:
	for index in range(result.tiles.size()):
		var tile_data: Dictionary = result.tiles[index]
		var coord: Vector2i = tile_data["axialCoord"]
		tile_states[coord] = {
			"rotation": int(tile_data["rotation"]),
			"locked": false,
			"active": index == 0,
			"isolated": false,
			"looped": false,
		}
	spawn_coord = result.tiles[0]["axialCoord"]
	has_spawn = true


func _randomize_states_direct() -> void:
	for coord: Vector2i in tile_states:
		var state: Dictionary = tile_states[coord]
		if not state["locked"]:
			state["rotation"] = rng.randi_range(0, 5)
			tile_states[coord] = state


func _instantiate_tile_views() -> void:
	var bounds_length := maxf(result.bounds.size.length(), 0.001)
	for tile_data: Dictionary in result.tiles:
		var coord: Vector2i = tile_data["axialCoord"]
		var view := tile.instantiate() as Tile
		view.set_script(tileScript)
		view.setup(
			tile_data["asset_key"],
			coord,
			tileSize,
			result.orientation,
			result.tile_rotation_offset_degrees,
			bounds_length
		)
		tiles[coord] = view
		add_child(view)


func _get_exit_neighbors(coord: Vector2i) -> Array[Vector2i]:
	var output: Array[Vector2i] = []
	var index: int = result.coordinate_to_index[coord]
	var tile_data: Dictionary = result.tiles[index]
	var state: Dictionary = tile_states[coord]
	for base_direction: int in Tile.SOURCES[tile_data["asset_key"]][2]:
		var direction := posmod(base_direction + int(state["rotation"]), 6)
		var neighbor_index: int = result.neighbors[index][direction]
		if neighbor_index >= 0:
			output.append(result.tiles[neighbor_index]["axialCoord"])
	return output


func _has_exit_towards(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	return _get_exit_neighbors(from_coord).has(to_coord)


func _correct_rotation(coord: Vector2i) -> int:
	var index: int = result.coordinate_to_index[coord]
	return int(result.tiles[index]["rotation"])


func _is_correct(coord: Vector2i) -> bool:
	var index: int = result.coordinate_to_index[coord]
	var tile_data: Dictionary = result.tiles[index]
	var symmetry: int = Tile.SOURCES[tile_data["asset_key"]][3]
	return _correct_rotation(coord) == posmod(int(tile_states[coord]["rotation"]), symmetry)


func _sync_all_tile_views(immediately: bool) -> void:
	for coord: Vector2i in tiles:
		var state: Dictionary = tile_states[coord]
		tiles[coord].apply_visual_state(
			state["rotation"],
			state["locked"],
			has_spawn and coord == spawn_coord,
			state["active"],
			state["isolated"],
			state["looped"],
			_is_correct(coord),
			isDone,
			immediately
		)


func _core_state(coord: Vector2i) -> Dictionary:
	return {
		"rotation": int(tile_states[coord]["rotation"]),
		"locked": bool(tile_states[coord]["locked"]),
	}


func _make_action_record(
	name: String,
	coord: Vector2i,
	before: Dictionary,
	after: Dictionary
) -> Dictionary:
	return {
		"name": name,
		"changes": [{"coord": coord, "before": before, "after": after}],
	}


func _commit_action_record(record: Dictionary) -> bool:
	var changes: Array = record.get("changes", [])
	var changes_spawn := record.has("spawn_before") or record.has("spawn_after")
	if changes.is_empty() and not changes_spawn:
		return false

	var current_action := undo_redo.get_current_action()
	if current_action + 1 < _history_records.size():
		_history_records.resize(current_action + 1)
	_history_records.append(record.duplicate(true))

	undo_redo.create_action(record.get("name", "Puzzle action"))
	undo_redo.add_do_method(_apply_action_record.bind(record, true))
	undo_redo.add_undo_method(_apply_action_record.bind(record, false))
	undo_redo.commit_action()
	_trim_history_if_needed()
	_queue_autosave()
	_emit_undo_state()
	return true


func _apply_action_record(record: Dictionary, use_after: bool) -> void:
	var state_key := "after" if use_after else "before"
	for change: Dictionary in record.get("changes", []):
		var coord: Vector2i = change["coord"]
		if not tile_states.has(coord):
			continue
		var core: Dictionary = change[state_key]
		var state: Dictionary = tile_states[coord]
		state["rotation"] = int(core["rotation"])
		state["locked"] = bool(core["locked"])
		tile_states[coord] = state

	var spawn_key := "spawn_after" if use_after else "spawn_before"
	if record.has(spawn_key):
		var saved_spawn: Variant = record[spawn_key]
		has_spawn = saved_spawn is Vector2i
		if has_spawn:
			spawn_coord = saved_spawn
	validate()


func _reset_history_to_current_state() -> void:
	undo_redo.clear_history(false)
	_history_records.clear()
	_history_base_states = _copy_core_states(tile_states)
	_history_base_spawn = spawn_coord
	_history_base_has_spawn = has_spawn
	_emit_undo_state()


func _copy_core_states(source: Dictionary[Vector2i, Dictionary]) -> Dictionary[Vector2i, Dictionary]:
	var copied: Dictionary[Vector2i, Dictionary] = {}
	for coord: Vector2i in source:
		copied[coord] = {
			"rotation": int(source[coord]["rotation"]),
			"locked": bool(source[coord]["locked"]),
		}
	return copied


func _trim_history_if_needed() -> void:
	while _history_records.size() > MAX_HISTORY_STEPS:
		var removed: Dictionary = _history_records.pop_front()
		_apply_record_to_base(removed)


func _apply_record_to_base(record: Dictionary) -> void:
	for change: Dictionary in record.get("changes", []):
		var coord: Vector2i = change["coord"]
		_history_base_states[coord] = change["after"].duplicate(true)
	if record.has("spawn_after"):
		var saved_spawn: Variant = record["spawn_after"]
		_history_base_has_spawn = saved_spawn is Vector2i
		if _history_base_has_spawn:
			_history_base_spawn = saved_spawn


func _emit_undo_state() -> void:
	undo_state_changed.emit(undo_redo.has_undo(), undo_redo.has_redo())


func export_puzzle_json(include_history: bool = true, pretty: bool = false) -> String:
	if result == null or tile_states.is_empty():
		return ""
	var payload := _build_puzzle_payload(include_history)
	return JSON.stringify(payload, "\t" if pretty else "", true)


func import_puzzle_json(serialized: String) -> Error:
	return _import_puzzle_json(serialized, true)


func get_last_import_error() -> String:
	return _last_import_error


func save_puzzle_autosave() -> Error:
	if result == null or tile_states.is_empty():
		return ERR_DOES_NOT_EXIST
	var file := FileAccess.open(AUTOSAVE_PATH, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		push_error("Could not open puzzle autosave for writing: error %d" % open_error)
		return open_error
	file.store_string(export_puzzle_json(true, false))
	file.close()
	return OK


func load_puzzle_autosave() -> Error:
	if not FileAccess.file_exists(AUTOSAVE_PATH):
		return ERR_FILE_NOT_FOUND
	var file := FileAccess.open(AUTOSAVE_PATH, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var serialized := file.get_as_text()
	file.close()
	var error := _import_puzzle_json(serialized, false)
	if error != OK:
		_preserve_invalid_autosave(serialized)
	return error


func clear_puzzle_autosave() -> Error:
	if not FileAccess.file_exists(AUTOSAVE_PATH):
		return OK
	var directory := DirAccess.open("user://")
	if directory == null:
		return DirAccess.get_open_error()
	return directory.remove(AUTOSAVE_PATH.get_file())


func _queue_autosave() -> void:
	if not _suppress_side_effects and _autosave_timer != null:
		_autosave_timer.start()


func _preserve_invalid_autosave(serialized: String) -> void:
	var backup := FileAccess.open(INVALID_AUTOSAVE_PATH, FileAccess.WRITE)
	if backup == null:
		return
	backup.store_string(serialized)
	backup.close()
	clear_puzzle_autosave()


func _build_puzzle_payload(include_history: bool) -> Dictionary:
	var initial_states := _history_base_states if include_history else _copy_core_states(tile_states)
	var initial_spawn := _history_base_spawn if include_history else spawn_coord
	var initial_has_spawn := _history_base_has_spawn if include_history else has_spawn
	var actions: Array = []
	if include_history:
		for record: Dictionary in _history_records:
			actions.append(_action_record_to_json(record))

	return {
		"format": PUZZLE_FORMAT,
		"version": PUZZLE_FORMAT_VERSION,
		"puzzle": {
			"definition": _result_to_json(),
			"initial_state": _state_snapshot_to_json(
				initial_states,
				initial_spawn,
				initial_has_spawn
			),
			"has_been_completed": hasBeenDone,
		},
		"history": {
			"current_action": undo_redo.get_current_action() if include_history else -1,
			"actions": actions,
		},
	}


func _result_to_json() -> Dictionary:
	var serialized_tiles: Array = []
	for tile_data: Dictionary in result.tiles:
		serialized_tiles.append({
			"coord": _coord_to_json(tile_data["axialCoord"]),
			"asset": tile_data["asset_key"],
			"correct_rotation": int(tile_data["rotation"]),
		})

	var serialized_neighbors: Array = []
	for neighbors: PackedInt32Array in result.neighbors:
		var row: Array = []
		for neighbor_index: int in neighbors:
			row.append(neighbor_index)
		serialized_neighbors.append(row)

	return {
		"layout": result.layout,
		"rectangle_mode": result.rectangle_mode,
		"orientation": result.orientation,
		"offset_parity": result.offset_parity,
		"max_spiral_index": result.max_spiral_index,
		"radius": result.radius,
		"width": result.width,
		"height": result.height,
		"wraparound": result.wraparound,
		"wrap_width": result.wrap_width,
		"wrap_height": result.wrap_height,
		"tile_rotation_offset_degrees": result.tile_rotation_offset_degrees,
		"seed": str(result.customSeed),
		"require_unique": result.require_unique,
		"unique_solution_verified": result.unique_solution_verified,
		"solution_count": result.solution_count,
		"attempts": result.attempts,
		"bounds": [
			result.bounds.position.x,
			result.bounds.position.y,
			result.bounds.size.x,
			result.bounds.size.y,
		],
		"tiles": serialized_tiles,
		"neighbors": serialized_neighbors,
	}


func _state_snapshot_to_json(
	states: Dictionary[Vector2i, Dictionary],
	saved_spawn: Vector2i,
	saved_has_spawn: bool
) -> Dictionary:
	var serialized_states: Array = []
	for coord: Vector2i in states:
		serialized_states.append({
			"coord": _coord_to_json(coord),
			"rotation": int(states[coord]["rotation"]),
			"locked": bool(states[coord]["locked"]),
		})
	return {
		"spawn": _coord_to_json(saved_spawn) if saved_has_spawn else null,
		"tiles": serialized_states,
	}


func _action_record_to_json(record: Dictionary) -> Dictionary:
	var serialized_changes: Array = []
	for change: Dictionary in record.get("changes", []):
		serialized_changes.append({
			"coord": _coord_to_json(change["coord"]),
			"before": change["before"].duplicate(true),
			"after": change["after"].duplicate(true),
		})
	var output := {
		"name": String(record.get("name", "Puzzle action")),
		"changes": serialized_changes,
	}
	if record.has("spawn_before"):
		output["spawn_before"] = (
			_coord_to_json(record["spawn_before"])
			if record["spawn_before"] is Vector2i
			else null
		)
		output["spawn_after"] = (
			_coord_to_json(record["spawn_after"])
			if record["spawn_after"] is Vector2i
			else null
		)
	return output


func _coord_to_json(coord: Vector2i) -> Array:
	return [coord.x, coord.y]


func _import_puzzle_json(serialized: String, autosave_after: bool) -> Error:
	_last_import_error = ""
	if serialized.to_utf8_buffer().size() > MAX_IMPORT_BYTES:
		return _fail_import("Puzzle data exceeds the %d byte limit." % MAX_IMPORT_BYTES)

	var json := JSON.new()
	var parse_error := json.parse(serialized)
	if parse_error != OK:
		return _fail_import(
			"JSON parse error on line %d: %s"
			% [json.get_error_line(), json.get_error_message()],
			parse_error
		)
	if not json.data is Dictionary:
		return _fail_import("Puzzle data must be a JSON object.")

	var decoded := _decode_puzzle_payload(json.data)
	if not decoded["error"].is_empty():
		return _fail_import(decoded["error"])

	_install_decoded_puzzle(decoded)
	if autosave_after:
		_queue_autosave()
	return OK


func _install_decoded_puzzle(decoded: Dictionary) -> void:
	_suppress_side_effects = true
	clear()
	result = decoded["result"]
	puzzle = result.tiles
	tileCount = result.total_tiles
	hasBeenDone = decoded["has_been_completed"]
	isDone = false

	_history_base_states = _copy_core_states(decoded["base_states"])
	_history_base_spawn = decoded["base_spawn"]
	_history_base_has_spawn = decoded["base_has_spawn"]
	tile_states = _states_with_derived_defaults(_history_base_states)
	spawn_coord = _history_base_spawn
	has_spawn = _history_base_has_spawn

	_instantiate_tile_views()
	_configure_repetition()
	_frame_board(true)
	validate()

	undo_redo.clear_history(false)
	_history_records.clear()
	for record: Dictionary in decoded["actions"]:
		_history_records.append(record.duplicate(true))
		undo_redo.create_action(record["name"])
		undo_redo.add_do_method(_apply_action_record.bind(record, true))
		undo_redo.add_undo_method(_apply_action_record.bind(record, false))
		undo_redo.commit_action()

	var saved_action: int = decoded["current_action"]
	while undo_redo.get_current_action() > saved_action:
		undo_redo.undo()

	validate()
	_sync_all_tile_views(true)
	_suppress_side_effects = false
	validated.emit(isDone)
	_emit_undo_state()
	newPuzzle.emit()


func _states_with_derived_defaults(
	core_states: Dictionary[Vector2i, Dictionary]
) -> Dictionary[Vector2i, Dictionary]:
	var states: Dictionary[Vector2i, Dictionary] = {}
	for coord: Vector2i in core_states:
		states[coord] = {
			"rotation": int(core_states[coord]["rotation"]),
			"locked": bool(core_states[coord]["locked"]),
			"active": false,
			"isolated": false,
			"looped": false,
		}
	return states


func _decode_puzzle_payload(payload: Dictionary) -> Dictionary:
	if payload.get("format") != PUZZLE_FORMAT:
		return {"error": "This is not a HexNet puzzle export."}
	var version: Variant = _decode_int(payload.get("version"), 1, PUZZLE_FORMAT_VERSION)
	if version == null or version != PUZZLE_FORMAT_VERSION:
		return {"error": "Unsupported puzzle format version."}

	var puzzle_data: Variant = payload.get("puzzle")
	var history_data: Variant = payload.get("history")
	if not puzzle_data is Dictionary or not history_data is Dictionary:
		return {"error": "Puzzle or history section is missing."}

	var decoded_result := _decode_result_definition(puzzle_data.get("definition"))
	if not decoded_result["error"].is_empty():
		return decoded_result
	var imported_result: HexNetGenerator.GenerationResult = decoded_result["result"]

	var decoded_state := _decode_state_snapshot(
		puzzle_data.get("initial_state"),
		imported_result.coordinate_to_index
	)
	if not decoded_state["error"].is_empty():
		return decoded_state

	var completed_value: Variant = puzzle_data.get("has_been_completed", false)
	if not completed_value is bool:
		return {"error": "has_been_completed must be a boolean."}

	var action_data: Variant = history_data.get("actions")
	if not action_data is Array or action_data.size() > MAX_HISTORY_STEPS:
		return {"error": "History must be an array with at most %d actions." % MAX_HISTORY_STEPS}
	var actions: Array[Dictionary] = []
	for action_value: Variant in action_data:
		var decoded_action := _decode_action_record(
			action_value,
			imported_result.coordinate_to_index
		)
		if not decoded_action["error"].is_empty():
			return decoded_action
		actions.append(decoded_action["record"])

	var current_action_value: Variant = _decode_int(
		history_data.get("current_action"),
		-1,
		actions.size() - 1
	)
	if current_action_value == null:
		return {"error": "History current_action is out of range."}

	var chain_error := _validate_history_chain(
		decoded_state["states"],
		decoded_state["spawn"],
		decoded_state["has_spawn"],
		actions
	)
	if not chain_error.is_empty():
		return {"error": chain_error}

	return {
		"error": "",
		"result": imported_result,
		"base_states": decoded_state["states"],
		"base_spawn": decoded_state["spawn"],
		"base_has_spawn": decoded_state["has_spawn"],
		"actions": actions,
		"current_action": int(current_action_value),
		"has_been_completed": completed_value,
	}


func _decode_result_definition(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"error": "Puzzle definition is missing."}
	var data: Dictionary = value
	var layout: Variant = _decode_int(data.get("layout"), 0, 2)
	var rectangle_mode: Variant = _decode_int(data.get("rectangle_mode"), 0, 1)
	var orientation: Variant = _decode_int(data.get("orientation"), 0, 1)
	var offset_parity: Variant = _decode_int(data.get("offset_parity"), 0, 1)
	if layout == null or rectangle_mode == null or orientation == null or offset_parity == null:
		return {"error": "Puzzle definition contains an invalid layout enum."}

	var tiles_data: Variant = data.get("tiles")
	var neighbors_data: Variant = data.get("neighbors")
	if (
		not tiles_data is Array
		or tiles_data.size() < 2
		or tiles_data.size() > MAX_IMPORT_TILES
		or not neighbors_data is Array
		or neighbors_data.size() != tiles_data.size()
	):
		return {"error": "Puzzle contains an invalid number of tiles or neighbor rows."}

	var imported := HexNetGenerator.GenerationResult.new()
	imported.layout = layout
	imported.rectangle_mode = rectangle_mode
	imported.orientation = orientation
	imported.offset_parity = offset_parity

	for bool_key in [
		"wraparound",
		"wrap_width",
		"wrap_height",
		"require_unique",
		"unique_solution_verified",
	]:
		if not data.get(bool_key) is bool:
			return {"error": "Puzzle definition field '%s' must be boolean." % bool_key}
	imported.wraparound = data["wraparound"]
	imported.wrap_width = data["wrap_width"]
	imported.wrap_height = data["wrap_height"]
	imported.require_unique = data["require_unique"]
	imported.unique_solution_verified = data["unique_solution_verified"]

	var max_spiral_index: Variant = _decode_int(data.get("max_spiral_index"), -1, 100000)
	var radius: Variant = _decode_int(data.get("radius"), -1, 10000)
	var width: Variant = _decode_int(data.get("width"), 0, 10000)
	var height: Variant = _decode_int(data.get("height"), 0, 10000)
	var solution_count: Variant = _decode_int(data.get("solution_count"), -1, 100000)
	var attempts: Variant = _decode_int(data.get("attempts"), 0, 1000000)
	if (
		max_spiral_index == null
		or radius == null
		or width == null
		or height == null
		or solution_count == null
		or attempts == null
	):
		return {"error": "Puzzle definition contains invalid numeric metadata."}
	imported.max_spiral_index = max_spiral_index
	imported.radius = radius
	imported.width = width
	imported.height = height
	imported.solution_count = solution_count
	imported.attempts = attempts

	var rotation_offset: Variant = _decode_float(data.get("tile_rotation_offset_degrees"))
	if rotation_offset == null:
		return {"error": "Puzzle rotation offset is invalid."}
	imported.tile_rotation_offset_degrees = rotation_offset
	var seed_value: Variant = data.get("seed")
	if seed_value is String and seed_value.is_valid_int():
		imported.customSeed = seed_value.to_int()
	elif seed_value is int or seed_value is float:
		imported.customSeed = int(seed_value)
	else:
		return {"error": "Puzzle seed is invalid."}

	var bounds_data: Variant = data.get("bounds")
	if not bounds_data is Array or bounds_data.size() != 4:
		return {"error": "Puzzle bounds must contain four numbers."}
	var bounds_numbers: Array[float] = []
	for component: Variant in bounds_data:
		var decoded_component: Variant = _decode_float(component)
		if decoded_component == null:
			return {"error": "Puzzle bounds contain an invalid number."}
		bounds_numbers.append(decoded_component)
	imported.bounds = Rect2(
		bounds_numbers[0],
		bounds_numbers[1],
		bounds_numbers[2],
		bounds_numbers[3]
	)
	if imported.bounds.size.x <= 0.0 or imported.bounds.size.y <= 0.0:
		return {"error": "Puzzle bounds must have a positive size."}

	for index in range(tiles_data.size()):
		var tile_value: Variant = tiles_data[index]
		if not tile_value is Dictionary:
			return {"error": "Tile %d is not an object." % index}
		var coord: Variant = _decode_coord(tile_value.get("coord"))
		var asset: Variant = tile_value.get("asset")
		var correct_rotation: Variant = _decode_int(tile_value.get("correct_rotation"), 0, 5)
		if coord == null or not asset is String or not Tile.SOURCES.has(asset) or correct_rotation == null:
			return {"error": "Tile %d contains invalid definition data." % index}
		if imported.coordinate_to_index.has(coord):
			return {"error": "Puzzle contains duplicate coordinate %s." % coord}
		imported.coordinate_to_index[coord] = index
		imported.tiles.append({
			"axialCoord": coord,
			"asset_key": asset,
			"rotation": int(correct_rotation),
		})

	for index in range(neighbors_data.size()):
		var row_value: Variant = neighbors_data[index]
		if not row_value is Array or row_value.size() != 6:
			return {"error": "Neighbor row %d must contain six indices." % index}
		var row := PackedInt32Array()
		for neighbor_value: Variant in row_value:
			var neighbor: Variant = _decode_int(neighbor_value, -1, tiles_data.size() - 1)
			if neighbor == null or neighbor == index:
				return {"error": "Neighbor row %d contains an invalid index." % index}
			row.append(neighbor)
		imported.neighbors.append(row)

	var topology_error := _validate_imported_topology(imported)
	if not topology_error.is_empty():
		return {"error": topology_error}
	imported.total_tiles = imported.tiles.size()
	return {"error": "", "result": imported}


func _validate_imported_topology(imported: HexNetGenerator.GenerationResult) -> String:
	for index in range(imported.neighbors.size()):
		for direction in range(6):
			var neighbor := imported.neighbors[index][direction]
			if neighbor < 0:
				continue
			if imported.neighbors[neighbor][HexNetGenerator.opposite_direction(direction)] != index:
				return "Puzzle topology is not reciprocal."

	var visited: Dictionary[int, bool] = {0: true}
	var queue: Array[int] = [0]
	var head := 0
	while head < queue.size():
		var index := queue[head]
		head += 1
		for neighbor: int in imported.neighbors[index]:
			if neighbor >= 0 and not visited.has(neighbor):
				visited[neighbor] = true
				queue.append(neighbor)
	if visited.size() != imported.tiles.size():
		return "Puzzle topology is disconnected."
	return ""


func _decode_state_snapshot(value: Variant, valid_coords: Dictionary) -> Dictionary:
	if not value is Dictionary:
		return {"error": "Initial puzzle state is missing."}
	var states_data: Variant = value.get("tiles")
	if not states_data is Array or states_data.size() != valid_coords.size():
		return {"error": "Initial state must contain every puzzle tile exactly once."}

	var states: Dictionary[Vector2i, Dictionary] = {}
	for state_value: Variant in states_data:
		if not state_value is Dictionary:
			return {"error": "Initial tile state is not an object."}
		var coord: Variant = _decode_coord(state_value.get("coord"))
		var rotation: Variant = _decode_int(state_value.get("rotation"), 0, 5)
		var locked: Variant = state_value.get("locked")
		if (
			coord == null
			or not valid_coords.has(coord)
			or states.has(coord)
			or rotation == null
			or not locked is bool
		):
			return {"error": "Initial state contains invalid tile data."}
		states[coord] = {"rotation": int(rotation), "locked": locked}

	var spawn_value: Variant = value.get("spawn")
	var decoded_spawn: Variant = null
	if spawn_value != null:
		decoded_spawn = _decode_coord(spawn_value)
		if decoded_spawn == null or not valid_coords.has(decoded_spawn):
			return {"error": "Initial state references an invalid spawn tile."}
	return {
		"error": "",
		"states": states,
		"spawn": decoded_spawn if decoded_spawn is Vector2i else Vector2i.ZERO,
		"has_spawn": decoded_spawn is Vector2i,
	}


func _decode_action_record(value: Variant, valid_coords: Dictionary) -> Dictionary:
	if not value is Dictionary:
		return {"error": "History action is not an object."}
	var name_value: Variant = value.get("name")
	var changes_value: Variant = value.get("changes")
	if not name_value is String or not changes_value is Array or changes_value.size() > valid_coords.size():
		return {"error": "History action contains an invalid name or change list."}

	var record := {"name": name_value, "changes": []}
	var changed_coords: Dictionary[Vector2i, bool] = {}
	for change_value: Variant in changes_value:
		if not change_value is Dictionary:
			return {"error": "History tile change is not an object."}
		var coord: Variant = _decode_coord(change_value.get("coord"))
		var before := _decode_core_state(change_value.get("before"))
		var after := _decode_core_state(change_value.get("after"))
		if (
			coord == null
			or not valid_coords.has(coord)
			or changed_coords.has(coord)
			or not before["error"].is_empty()
			or not after["error"].is_empty()
		):
			return {"error": "History action contains an invalid tile change."}
		changed_coords[coord] = true
		record["changes"].append({
			"coord": coord,
			"before": before["state"],
			"after": after["state"],
		})

	var has_spawn_before: bool = value.has("spawn_before")
	var has_spawn_after: bool = value.has("spawn_after")
	if has_spawn_before != has_spawn_after:
		return {"error": "History spawn changes require before and after values."}
	if has_spawn_before:
		for key in ["spawn_before", "spawn_after"]:
			var spawn_value: Variant = value[key]
			if spawn_value == null:
				record[key] = null
				continue
			var spawn_coord_value: Variant = _decode_coord(spawn_value)
			if spawn_coord_value == null or not valid_coords.has(spawn_coord_value):
				return {"error": "History action references an invalid spawn tile."}
			record[key] = spawn_coord_value

	if record["changes"].is_empty() and not has_spawn_before:
		return {"error": "History action has no changes."}
	return {"error": "", "record": record}


func _decode_core_state(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"error": "State is not an object."}
	var rotation: Variant = _decode_int(value.get("rotation"), 0, 5)
	var locked: Variant = value.get("locked")
	if rotation == null or not locked is bool:
		return {"error": "State contains an invalid rotation or lock value."}
	return {
		"error": "",
		"state": {"rotation": int(rotation), "locked": locked},
	}


func _validate_history_chain(
	base_states: Dictionary[Vector2i, Dictionary],
	base_spawn: Vector2i,
	base_has_spawn: bool,
	actions: Array[Dictionary]
) -> String:
	var simulated := _copy_core_states(base_states)
	var simulated_spawn := base_spawn
	var simulated_has_spawn := base_has_spawn
	for record: Dictionary in actions:
		for change: Dictionary in record["changes"]:
			var coord: Vector2i = change["coord"]
			if simulated[coord] != change["before"]:
				return "History does not connect to its preceding tile state."
			simulated[coord] = change["after"].duplicate(true)
		if record.has("spawn_before"):
			var before_spawn: Variant = record["spawn_before"]
			if (before_spawn is Vector2i) != simulated_has_spawn:
				return "History does not connect to its preceding spawn state."
			if simulated_has_spawn and before_spawn != simulated_spawn:
				return "History contains a mismatched spawn state."
			var after_spawn: Variant = record["spawn_after"]
			simulated_has_spawn = after_spawn is Vector2i
			if simulated_has_spawn:
				simulated_spawn = after_spawn
	return ""


func _decode_coord(value: Variant) -> Variant:
	if not value is Array or value.size() != 2:
		return null
	var x: Variant = _decode_int(value[0], -10000, 10000)
	var y: Variant = _decode_int(value[1], -10000, 10000)
	if x == null or y == null:
		return null
	return Vector2i(x, y)


func _decode_int(value: Variant, minimum: int, maximum: int) -> Variant:
	if not (value is int or value is float):
		return null
	var number := float(value)
	if is_nan(number) or is_inf(number) or number != floorf(number):
		return null
	var decoded := int(number)
	return decoded if decoded >= minimum and decoded <= maximum else null


func _decode_float(value: Variant) -> Variant:
	if not (value is int or value is float):
		return null
	var decoded := float(value)
	return null if is_nan(decoded) or is_inf(decoded) else decoded


func _fail_import(message: String, error: Error = ERR_INVALID_DATA) -> Error:
	_last_import_error = message
	push_warning(message)
	return error


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
