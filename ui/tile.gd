class_name Tile
extends Node2D

@onready var anchor: Node2D = $rotationAnchor
@onready var asset_fill: Sprite2D = $fill
@onready var asset_node_active: Sprite2D = $node_active
@onready var asset_dot: Sprite2D = $dot
@onready var asset_spec: Sprite2D = $rotationAnchor/spec
@onready var asset_spec_active: Sprite2D = $rotationAnchor/spec_active
@onready var asset_dot_active: Sprite2D = $dot_active

var grid: HexGrid

signal rotated

static var SOURCES := {
	"target": ["res://assets/hex/2_line_1.png", "res://assets/hex/2_line_active_1.png", [0], 6, true],
	"2_corner": ["res://assets/hex/2_corner.png", "res://assets/hex/2_corner_active.png", [0, 2], 6, false],
	"2_hairpin": ["res://assets/hex/2_hairpin.png", "res://assets/hex/2_hairpin_active.png", [0, 1], 6, false],
	"2_line": ["res://assets/hex/2_line.png", "res://assets/hex/2_line_active.png", [0, 3], 3, false],
	"3_branch": ["res://assets/hex/3_branch.png", "res://assets/hex/3_branch_active.png", [0, 2, 3], 6, false],
	"3_branch_alt": ["res://assets/hex/3_branch_alt.png", "res://assets/hex/3_branch_alt_active.png", [0, 3, 4], 6, false],
	"3_even": ["res://assets/hex/3_even.png", "res://assets/hex/3_even_active.png", [0, 2, 4], 2, false],
	"3_side": ["res://assets/hex/3_side.png", "res://assets/hex/3_side_active.png", [0, 1, 5], 6, false],
	"4_branch": ["res://assets/hex/4_branch.png", "res://assets/hex/4_branch_active.png", [0, 1, 3, 5], 6, false],
	"4_even": ["res://assets/hex/4_even.png", "res://assets/hex/4_even_active.png", [0, 2, 3, 5], 3, false],
	"4_side": ["res://assets/hex/4_side.png", "res://assets/hex/4_side_active.png", [0, 1, 2, 3], 6, false],
	"5": ["res://assets/hex/5.png", "res://assets/hex/5_active.png", [0, 1, 2, 4, 5], 6, false],
	"6": ["res://assets/hex/6.png", "res://assets/hex/6_active.png", [0, 1, 2, 3, 4, 5], 1, false],
}

var source_assets: Array[String]

var topology_neighbors: Dictionary[int, Vector2i] = {}

func setup(
	given_index: int,
	given_key: String,
	given_coord: Vector2,
	given_spawn: bool,
	given_rotation: int,
	given_tileSize,
	given_result: HexNetGenerator.GenerationResult,
	given_grid: HexGrid
)->void:
	var asset = SOURCES[given_key];
	asset_key = given_key

	dot = asset[4]

	source_assets = [asset[0], asset[1]]

	spawn = given_spawn
	active = given_spawn

	axialCoord = given_coord
	rotationTarget = given_rotation
	correct = given_rotation
	tileSize = given_tileSize

	position = (
		HexNetGenerator.axial_to_unit(given_coord, given_result.orientation)
		* given_tileSize
	)

	rotation_degrees = given_result.tile_rotation_offset_degrees
	grid = given_grid

	rotated.connect(grid.tileChanged)

	configure_topology(given_index, given_result)



func configure_topology(
	tile_index: int,
	result: HexNetGenerator.GenerationResult
) -> void:
	topology_neighbors.clear()

	for direction in range(6):
		var neighbor_index: int = result.neighbors[tile_index][direction]

		# -1 represents a genuine non-wrapped boundary.
		if neighbor_index < 0:
			continue

		var neighbor_data: Dictionary = result.tiles[neighbor_index]
		var neighbor_coord: Vector2i = neighbor_data["axialCoord"]

		topology_neighbors[direction] = neighbor_coord


func get_exit_neighbors() -> Array[Vector2i]:
	var output: Array[Vector2i] = []

	for base_direction: int in SOURCES[asset_key][2]:
		var direction := posmod(base_direction + rotationTarget, 6)

		# Missing only at a genuine boundary.
		if not topology_neighbors.has(direction):
			continue

		output.append(topology_neighbors[direction])

	return output
func has_exit_towards(v: Vector2i) -> bool:
	return get_exit_neighbors().has(v)

var tileSize: int
var rng = RandomNumberGenerator.new()
var asset_key: String = 'target'
var axialCoord: Vector2i = Vector2(0, 0)
var spawn: bool = false
var dot: bool = false
var active: bool = false
var isolated: bool = false
var loop: bool = false
var correct: int
var rotationTarget := 0
var lock: bool = false

var _active_color_target := Color(0.9, 0.9, 0.9)
var _lock_color_target := Color(0.3, 0.3, 0.4, 0.0)
var _visual_targets_dirty := true

func _match() -> bool:
	return correct == fposmod(rotationTarget, SOURCES[asset_key][3])

func _has_continuous_color_animation() -> bool:
	if grid.isDone and grid.getS('showCompletionRainbow'):
		return true
	return active and grid.getS('showSpawn') and grid.getS('showPathRainbow')


func _get_rainbow_color() -> Color:
	var duration_msec := 3000.0
	var bounds_length := maxf(grid.result.bounds.size.length(), 0.001)
	var phase_offset := axialCoord.length() / bounds_length * duration_msec * 1
	var hue := (Time.get_ticks_msec() + phase_offset) / duration_msec
	return Color.from_ok_hsl(hue, 1, 0.7)


func _get_active_color_target() -> Color:
	if _has_continuous_color_animation():
		return _get_rainbow_color()

	var activeColorTarget: Color = Color(0.9, 0.9, 0.9)

	if (lock and grid.getS('review')) or (not lock and grid.getS('reviewAll')):
		if _match():
			activeColorTarget = Color(0.5, 1, 0.5)
		else:
			activeColorTarget = Color(1, 0.5, 0.5)

	else:
		if loop and grid.getS('showLoops'):
			activeColorTarget = activeColorTarget * Color(1, 0.6, 0.6)
			pass
		if isolated and grid.getS('showIsolation') and not grid.isDone:
			activeColorTarget = activeColorTarget * Color(0.6, 0.6, 1)
			pass

	if (not active or not grid.getS('showSpawn')):
		activeColorTarget = activeColorTarget * Color(.6, .7, .8)

	return activeColorTarget


func _get_lock_color_target() -> Color:
	
	var lockColorTarget = Color(0.35, 0.35, 0.5, 0.8) if lock else Color(0.35, 0.35, 0.5, 0.0)

	if grid.isDone:
		lockColorTarget.a = 0

	return lockColorTarget

func _refresh_visual_targets() -> void:
	_active_color_target = _get_active_color_target()
	_lock_color_target = _get_lock_color_target()

	var show_spawn := grid.getS('showSpawn')
	var show_spawn_node := spawn and show_spawn and not grid.isDone
	asset_node_active.visible = show_spawn_node
	asset_dot.visible = dot or show_spawn_node
	asset_dot_active.visible = asset_dot.visible
	_visual_targets_dirty = false


func _apply_visual_targets(delta: float, immediately: bool = false) -> bool:
	var weight := 1.0 if immediately else 1.0 - exp(-grid.configUI.value_easeSpeed * delta)
	var rotation_target := rotationTarget / 6.0 * TAU

	asset_dot_active.modulate = lerp(
		asset_dot_active.modulate,
		_active_color_target,
		weight
	)
	asset_fill.modulate = lerp(asset_fill.modulate, _lock_color_target, weight)
	anchor.rotation = lerp_angle(anchor.rotation, rotation_target, weight)

	if immediately or _active_color_target.is_equal_approx(asset_dot_active.modulate):
		asset_dot_active.modulate = _active_color_target
	if immediately or _lock_color_target.is_equal_approx(asset_fill.modulate):
		asset_fill.modulate = _lock_color_target
	if immediately or absf(angle_difference(anchor.rotation, rotation_target)) < 0.0001:
		anchor.rotation = rotation_target

	asset_spec_active.modulate = asset_dot_active.modulate

	return (
		_active_color_target.is_equal_approx(asset_dot_active.modulate)
		and _lock_color_target.is_equal_approx(asset_fill.modulate)
		and absf(angle_difference(anchor.rotation, rotation_target)) < 0.0001
	)


func _process(delta: float) -> void:
	var continuously_animated := _has_continuous_color_animation()
	if _visual_targets_dirty:
		_refresh_visual_targets()
	elif continuously_animated:
		_active_color_target = _get_rainbow_color()

	if _apply_visual_targets(delta) and not continuously_animated:
		set_process(false)


func mark_visual_dirty() -> void:
	_visual_targets_dirty = true
	set_process(true)


func set_validation_state(
	new_active: bool,
	new_isolated: bool,
	new_loop: bool
) -> void:
	if active == new_active and isolated == new_isolated and loop == new_loop:
		return
	active = new_active
	isolated = new_isolated
	loop = new_loop
	mark_visual_dirty()


func set_spawn_state(new_spawn: bool) -> void:
	if spawn == new_spawn:
		return
	spawn = new_spawn
	mark_visual_dirty()

func secondary_click() -> void:
	lock = !lock
	mark_visual_dirty()

func primary_click() -> void:
	if lock: return
	if Input.is_key_pressed(KEY_SHIFT):
		tileRotate(rotationTarget - 1)
	else:
		tileRotate(rotationTarget + 1)
	if Input.is_key_pressed(KEY_CTRL) or grid.getS('autoSpawn'):
		grid.setSpawn(self)

func tileRotate(v: float, s: bool = true) -> void:
	var new_rotation := posmod(roundi(v), 6)
	if rotationTarget != new_rotation:
		rotationTarget = new_rotation
		mark_visual_dirty()
	if s:
		rotated.emit()

func randomRotate(s: bool = true) -> void:
	tileRotate(rng.randf() * 6, s)

func _ready() -> void:
	asset_spec.texture = load(source_assets[0])
	asset_spec_active.texture = load(source_assets[1])

	anchor.rotation = rotationTarget



func force() -> void:
	_refresh_visual_targets()
	_apply_visual_targets(0.0, true)
	set_process(_has_continuous_color_animation())
