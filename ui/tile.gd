class_name Tile
extends Node2D

## Passive animated view of one puzzle cell. HexGrid owns all puzzle state.

@onready var anchor: Node2D = $rotationAnchor
@onready var asset_fill: Sprite2D = $fill
@onready var asset_node_active: Sprite2D = $node_active
@onready var asset_dot: Sprite2D = $dot
@onready var asset_spec: Sprite2D = $rotationAnchor/spec
@onready var asset_spec_active: Sprite2D = $rotationAnchor/spec_active
@onready var asset_dot_active: Sprite2D = $dot_active

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

const RAINBOW_DURATION_MSEC := 3000
const RAINBOW_SATURATION := 1.0
const RAINBOW_LIGHTNESS := 0.7

static var _rainbow_lut: PackedColorArray = _build_rainbow_lut()


static func _build_rainbow_lut() -> PackedColorArray:
	var colors := PackedColorArray()
	colors.resize(RAINBOW_DURATION_MSEC)
	for index in range(RAINBOW_DURATION_MSEC):
		colors[index] = Color.from_ok_hsl(
			float(index) / RAINBOW_DURATION_MSEC,
			RAINBOW_SATURATION,
			RAINBOW_LIGHTNESS
		)
	return colors

var asset_key := "target"
var axial_coord := Vector2i.ZERO
var rotation_target := 0
var locked := false
var spawned := false
var active := false
var isolated := false
var looped := false
var is_correct := false
var puzzle_completed := false
var dot := false
var board_bounds_length := 1.0
var _rainbow_phase_msec := 0

var _source_assets: Array[String] = []
var _active_color_target := Color(0.9, 0.9, 0.9)
var _lock_color_target := Color(0.3, 0.3, 0.4, 0.0)
var _visual_targets_dirty := true


func setup(
	given_key: String,
	given_coord: Vector2i,
	tile_size: int,
	orientation: int,
	tile_rotation_offset_degrees: float,
	bounds_length: float
) -> void:
	var asset: Array = SOURCES[given_key]
	asset_key = given_key
	axial_coord = given_coord
	dot = asset[4]
	_source_assets = [asset[0], asset[1]]
	board_bounds_length = maxf(bounds_length, 0.001)
	_rainbow_phase_msec = posmod(
		roundi(
			axial_coord.length()
			/ board_bounds_length
			* RAINBOW_DURATION_MSEC
		),
		RAINBOW_DURATION_MSEC
	)
	position = HexNetGenerator.axial_to_unit(given_coord, orientation) * tile_size
	rotation_degrees = tile_rotation_offset_degrees


func apply_visual_state(
	new_rotation: int,
	new_locked: bool,
	new_spawned: bool,
	new_active: bool,
	new_isolated: bool,
	new_looped: bool,
	new_is_correct: bool,
	new_puzzle_completed: bool,
	immediately: bool = false
) -> void:
	var changed := (
		rotation_target != new_rotation
		or locked != new_locked
		or spawned != new_spawned
		or active != new_active
		or isolated != new_isolated
		or looped != new_looped
		or is_correct != new_is_correct
		or puzzle_completed != new_puzzle_completed
	)
	rotation_target = new_rotation
	locked = new_locked
	spawned = new_spawned
	active = new_active
	isolated = new_isolated
	looped = new_looped
	is_correct = new_is_correct
	puzzle_completed = new_puzzle_completed

	if changed or immediately:
		mark_visual_dirty()
	if immediately and is_node_ready():
		_refresh_visual_targets()
		_apply_visual_targets(0.0, true)
		set_process(_has_continuous_color_animation())


func _ready() -> void:
	asset_spec.texture = load(_source_assets[0])
	asset_spec_active.texture = load(_source_assets[1])
	anchor.rotation = rotation_target / 6.0 * TAU
	_refresh_visual_targets()
	_apply_visual_targets(0.0, true)
	set_process(_has_continuous_color_animation())


func _has_continuous_color_animation() -> bool:
	if SettingsStore.get_bool(SettingsStore.DISABLE_ANIMATION):
		return false
	if puzzle_completed and SettingsStore.get_bool(SettingsStore.COMPLETION_EFFECT):
		return true
	return (
		active
		and SettingsStore.get_bool(SettingsStore.SHOW_PATHS)
		and SettingsStore.get_bool(SettingsStore.RAINBOW_PATHS)
	)


func _get_rainbow_color() -> Color:
	var time_index := int(Time.get_ticks_msec() % RAINBOW_DURATION_MSEC)
	return _rainbow_lut[
		(time_index + _rainbow_phase_msec) % RAINBOW_DURATION_MSEC
	]


func _get_active_color_target() -> Color:
	if _has_continuous_color_animation():
		return _get_rainbow_color()

	var target := Color(0.9, 0.9, 0.9)
	if (
		locked and SettingsStore.get_bool(SettingsStore.REVIEW_LOCKED)
	) or (
		not locked and SettingsStore.get_bool(SettingsStore.REVIEW_UNLOCKED)
	):
		target = Color(0.5, 1.0, 0.5) if is_correct else Color(1.0, 0.5, 0.5)
	else:
		if looped and SettingsStore.get_bool(SettingsStore.SHOW_LOOP_ERRORS):
			target *= Color(1.0, 0.6, 0.6)
		if (
			isolated
			and SettingsStore.get_bool(SettingsStore.SHOW_ISOLATION_ERRORS)
			and not puzzle_completed
		):
			target *= Color(0.6, 0.6, 1.0)

	if not active or not SettingsStore.get_bool(SettingsStore.SHOW_PATHS):
		target *= Color(0.6, 0.7, 0.8)
	return target


func _get_lock_color_target() -> Color:
	var target := Color(0.35, 0.35, 0.5, 0.8) if locked else Color(0.35, 0.35, 0.5, 0.0)
	if puzzle_completed:
		target.a = 0.0
	return target


func _refresh_visual_targets() -> void:
	_active_color_target = _get_active_color_target()
	_lock_color_target = _get_lock_color_target()

	var show_paths := SettingsStore.get_bool(SettingsStore.SHOW_PATHS)
	var show_spawn_node := spawned and show_paths and not puzzle_completed
	asset_node_active.visible = show_spawn_node
	asset_dot.visible = dot or show_spawn_node
	asset_dot_active.visible = asset_dot.visible
	_visual_targets_dirty = false


func _apply_visual_targets(delta: float, immediately: bool = false) -> bool:
	var ease_speed := SettingsStore.get_float(SettingsStore.EASE_SPEED)
	var weight := 1.0 if immediately else 1.0 - exp(-ease_speed * delta)
	var rotation_radians := rotation_target / 6.0 * TAU

	asset_dot_active.modulate = lerp(asset_dot_active.modulate, _active_color_target, weight)
	asset_fill.modulate = lerp(asset_fill.modulate, _lock_color_target, weight)
	anchor.rotation = lerp_angle(anchor.rotation, rotation_radians, weight)

	if immediately or _active_color_target.is_equal_approx(asset_dot_active.modulate):
		asset_dot_active.modulate = _active_color_target
	if immediately or _lock_color_target.is_equal_approx(asset_fill.modulate):
		asset_fill.modulate = _lock_color_target
	if immediately or absf(angle_difference(anchor.rotation, rotation_radians)) < 0.0001:
		anchor.rotation = rotation_radians

	asset_spec_active.modulate = asset_dot_active.modulate
	return (
		_active_color_target.is_equal_approx(asset_dot_active.modulate)
		and _lock_color_target.is_equal_approx(asset_fill.modulate)
		and absf(angle_difference(anchor.rotation, rotation_radians)) < 0.0001
	)


func _process(delta: float) -> void:
	if SettingsStore.get_bool(SettingsStore.DISABLE_ANIMATION):
		_refresh_visual_targets()
		_apply_visual_targets(0.0, true)
		set_process(false)
		return

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
