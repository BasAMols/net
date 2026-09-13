class_name PlayfieldCamera
extends Camera2D

## Camera and pointer-gesture controller for the puzzle playfield.
##
## Positional input is handled in _unhandled_input() so Control-based UI gets
## first refusal, then this node performs the playfield's tile hit testing.

@export var grid: HexGrid
@export_range(0.25, 1, 0.05) var min_zoom_multiplier: float = 1
@export_range(1.0, 20.0, 0.25) var max_zoom_multiplier: float = 5.0
@export_range(1.01, 2.0, 0.01) var mouse_zoom_step: float = 1.15
@export_range(0.0, 32.0, 1.0) var drag_threshold_pixels: float = 6.0

@onready var hold_timer: Timer = $HoldTimer

var min_zoom: float = 1.0
var max_zoom: float = 5.0
var framed_bounds: Rect2 = Rect2()

var _middle_pending := false
var _middle_panning := false
var _middle_press_position := Vector2.ZERO
var _middle_last_position := Vector2.ZERO
var _middle_press_tile: Tile

var _primary_tile: Tile
var _primary_owned := false
var _primary_hold_triggered := false
var _secondary_owned := false

var _touches: Dictionary = {}
var _touch_gesture_active := false
var _single_touch_start_position := Vector2.ZERO


func _ready() -> void:
	hold_timer.timeout.connect(_on_hold_timeout)


func configure_bounds(
	new_bounds: Rect2,
	reset_view: bool,
	margin_pixels: float = 20.0
) -> void:
	framed_bounds = new_bounds

	var viewport_size := get_viewport().get_visible_rect().size
	var available_size := viewport_size - Vector2.ONE * margin_pixels * 2.0
	available_size.x = maxf(available_size.x, 1.0)
	available_size.y = maxf(available_size.y, 1.0)

	var previous_ratio := zoom.x / min_zoom if min_zoom > 0.0 else 1.0
	min_zoom = minf(
		available_size.x / maxf(framed_bounds.size.x, 1.0),
		available_size.y / maxf(framed_bounds.size.y, 1.0)
	) * min_zoom_multiplier
	max_zoom = min_zoom * max_zoom_multiplier

	if reset_view:
		global_position = framed_bounds.get_center()
		_set_zoom_value(min_zoom/min_zoom_multiplier)
	else:
		_set_zoom_value(clampf(min_zoom * previous_ratio, min_zoom, max_zoom))

	limit_enabled = false
	_wrap_camera_position()
	force_update_scroll()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_screen_touch(event)
		return

	if event is InputEventScreenDrag:
		_handle_screen_drag(event)
		return

	# Some platforms emit mouse-emulation events for the first touch. Once a
	# touch pan or pinch owns the sequence, suppress those events as well.
	if _touch_gesture_active and (
		event is InputEventMouseButton or event is InputEventMouseMotion
	):
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.pressed and event.button_index in [
		MOUSE_BUTTON_WHEEL_UP,
		MOUSE_BUTTON_WHEEL_DOWN,
	]:
		var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		var wheel_amount := maxf(event.factor, 0.01)
		var factor := pow(mouse_zoom_step, direction * wheel_amount)
		_zoom_around_screen_position(event.position, zoom.x * factor)
		get_viewport().set_input_as_handled()
		return

	match event.button_index:
		MOUSE_BUTTON_MIDDLE:
			_handle_middle_button(event)
		MOUSE_BUTTON_LEFT:
			_handle_primary_button(event)
		MOUSE_BUTTON_RIGHT:
			_handle_secondary_button(event)


func _handle_middle_button(event: InputEventMouseButton) -> void:
	if event.pressed:
		_cancel_primary_press()
		_primary_owned = false
		_middle_pending = true
		_middle_panning = false
		_middle_press_position = event.position
		_middle_last_position = event.position
		_middle_press_tile = _tile_at_screen_position(event.position)
	else:
		if not _middle_pending and not _middle_panning:
			return

		if _middle_pending and _middle_press_tile != null:
			grid.setSpawn(_middle_press_tile)

		_middle_pending = false
		_middle_panning = false
		_middle_press_tile = null

	get_viewport().set_input_as_handled()


func _handle_primary_button(event: InputEventMouseButton) -> void:
	if event.pressed:
		var tile := _tile_at_screen_position(event.position)
		if tile == null:
			return
		_cancel_primary_press()
		_primary_owned = true
		_primary_tile = tile
		_primary_hold_triggered = false
		hold_timer.start(SettingsStore.get_float(SettingsStore.HOLD_DELAY_MS) / 1000.0)
	else:
		if not _primary_owned:
			return
		var pressed_tile := _primary_tile
		var release_tile := _tile_at_screen_position(event.position)
		var should_click := (
			pressed_tile != null
			and release_tile == pressed_tile
			and not _primary_hold_triggered
		)
		_cancel_primary_press()
		if should_click:
			pressed_tile.primary_click()

	get_viewport().set_input_as_handled()


func _handle_secondary_button(event: InputEventMouseButton) -> void:
	if event.pressed:
		var tile := _tile_at_screen_position(event.position)
		if tile == null:
			return
		_secondary_owned = true
		tile.secondary_click()
	elif _secondary_owned:
		_secondary_owned = false
	else:
		return

	get_viewport().set_input_as_handled()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _primary_owned and _primary_tile != null:
		if _tile_at_screen_position(event.position) != _primary_tile:
			_cancel_primary_press()

	if not _middle_pending and not _middle_panning:
		return

	if _middle_pending:
		var total_motion := event.position - _middle_press_position
		if total_motion.length() <= drag_threshold_pixels:
			get_viewport().set_input_as_handled()
			return
		_middle_pending = false
		_middle_panning = true
		# Preserve the click dead-zone without making the camera jump when the
		# gesture first becomes a drag.
		var drag_motion := (
			total_motion
			- total_motion.normalized() * drag_threshold_pixels
		)
		_pan_between_screen_positions(
			_middle_press_position,
			_middle_press_position + drag_motion
		)
	else:
		_pan_between_screen_positions(_middle_last_position, event.position)

	_middle_last_position = event.position
	get_viewport().set_input_as_handled()


func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	var gesture_owned_event := _touch_gesture_active
	if event.pressed:
		if _touches.is_empty():
			_single_touch_start_position = event.position
		_touches[event.index] = event.position
		if _touches.size() >= 2 and not _touch_gesture_active:
			_touch_gesture_active = true
			gesture_owned_event = true
			_cancel_pointer_actions()
	else:
		_touches.erase(event.index)
		if _touch_gesture_active:
			if _touches.is_empty():
				_touch_gesture_active = false
			else:
				# A finger left after a pinch can continue panning immediately;
				# the overall gesture already crossed its activation boundary.
				_single_touch_start_position = _first_touch_position()

	if gesture_owned_event or _touch_gesture_active:
		get_viewport().set_input_as_handled()


func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	if not _touches.has(event.index):
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_single_touch_start_position = event.position

	if not _touch_gesture_active:
		if _touches.size() >= 2:
			_touch_gesture_active = true
			_cancel_pointer_actions()
		elif _touches.size() == 1:
			var total_motion := event.position - _single_touch_start_position
			_touches[event.index] = event.position
			if total_motion.length() <= drag_threshold_pixels:
				return

			_touch_gesture_active = true
			_cancel_pointer_actions()
			# As with middle-mouse panning, consume the dead-zone rather than
			# jumping the camera when the drag first becomes intentional.
			var drag_motion := (
				total_motion
				- total_motion.normalized() * drag_threshold_pixels
			)
			_pan_between_screen_positions(
				_single_touch_start_position,
				_single_touch_start_position + drag_motion
			)
			get_viewport().set_input_as_handled()
			return

	if _touches.size() == 1:
		var previous_position: Vector2 = _touches[event.index]
		_touches[event.index] = event.position
		_pan_between_screen_positions(previous_position, event.position)
		get_viewport().set_input_as_handled()
		return

	var old_pair := _first_two_touch_positions()
	_touches[event.index] = event.position
	var new_pair := _first_two_touch_positions()

	var old_center: Vector2 = (old_pair[0] + old_pair[1]) * 0.5
	var new_center: Vector2 = (new_pair[0] + new_pair[1]) * 0.5
	var old_distance: float = old_pair[0].distance_to(old_pair[1])
	var new_distance: float = new_pair[0].distance_to(new_pair[1])
	var new_zoom := zoom.x
	if old_distance > 0.001:
		new_zoom *= new_distance / old_distance

	_transform_around_screen_positions(old_center, new_center, new_zoom)
	get_viewport().set_input_as_handled()


func _first_two_touch_positions() -> Array[Vector2]:
	var keys := _touches.keys()
	return [
		_touches[keys[0]] as Vector2,
		_touches[keys[1]] as Vector2,
	]


func _first_touch_position() -> Vector2:
	var keys := _touches.keys()
	return _touches[keys[0]] as Vector2


func _zoom_around_screen_position(screen_position: Vector2, new_zoom: float) -> void:
	_transform_around_screen_positions(screen_position, screen_position, new_zoom)


func _pan_between_screen_positions(from: Vector2, to: Vector2) -> void:
	_transform_around_screen_positions(from, to, zoom.x)


func _transform_around_screen_positions(
	old_screen_position: Vector2,
	new_screen_position: Vector2,
	new_zoom: float
) -> void:
	var anchor_world := _screen_to_world(old_screen_position)
	_set_zoom_value(clampf(new_zoom, min_zoom, max_zoom))
	force_update_scroll()
	var moved_anchor_world := _screen_to_world(new_screen_position)
	global_position += anchor_world - moved_anchor_world
	_wrap_camera_position()
	force_update_scroll()


func _screen_to_world(screen_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position


func _tile_at_screen_position(screen_position: Vector2) -> Tile:
	if grid == null:
		return null
	return grid.tile_at_world_position(_screen_to_world(screen_position))


func _set_zoom_value(value: float) -> void:
	zoom = Vector2.ONE * value


func _wrap_camera_position() -> void:
	if grid != null:
		global_position = grid.wrap_world_position(global_position)


func _cancel_primary_press() -> void:
	hold_timer.stop()
	_primary_tile = null
	_primary_owned = false
	_primary_hold_triggered = false


func _on_hold_timeout() -> void:
	if not _primary_owned or _primary_tile == null:
		return
	_primary_hold_triggered = true
	_primary_tile.secondary_click()


func _cancel_pointer_actions() -> void:
	_cancel_primary_press()
	_secondary_owned = false
	_middle_pending = false
	_middle_panning = false
	_middle_press_tile = null
