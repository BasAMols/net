extends Node

## The single source of truth for user settings.
##
## This autoload owns the schema, current values, persistence, validation, and
## automatic binding of every ActionBase that enters the scene tree.

signal setting_changed(setting_key: StringName, value: Variant)

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_VERSION := 1
const SAVE_DELAY_SECONDS := 0.4

const UNIQUE_SOLUTION := &"new_game/unique_solution"
const WRAP := &"new_game/wrap"
const RADIUS := &"new_game/radius"
const ORIENTATION := &"new_game/orientation"
const LAYOUT := &"new_game/layout"
const RECTANGLE_WIDTH := &"new_game/rectangle_width"
const RECTANGLE_HEIGHT := &"new_game/rectangle_height"

const SHOW_PATHS := &"visual/show_paths"
const RAINBOW_PATHS := &"visual/rainbow_paths"
const COMPLETION_EFFECT := &"visual/completion_effect"
const SHOW_LOOP_ERRORS := &"visual/show_loop_errors"
const SHOW_ISOLATION_ERRORS := &"visual/show_isolation_errors"
const SHOW_GHOST := &"visual/show_ghost"
const REVIEW_LOCKED := &"visual/review_locked"
const REVIEW_UNLOCKED := &"visual/review_unlocked"
const DISABLE_ANIMATION := &"visual/disable_animation"

const AUTO_MOVE_SOURCE := &"interaction/auto_move_source"
const EASE_SPEED := &"interaction/ease_speed"
const HOLD_DELAY_MS := &"interaction/hold_delay_ms"

const WINDOW_SIZE := &"window/size"
const WINDOW_MAXIMIZED := &"window/maximized"

## Settings may exist without a UI control. Multiple controls may reference the
## same key; all of them are synchronized by this store.
const DEFINITIONS := {
	UNIQUE_SOLUTION: {
		"type": TYPE_BOOL,
		"default": true,
	},
	WRAP: {
		"type": TYPE_BOOL,
		"default": false,
	},
	RADIUS: {
		"type": TYPE_INT,
		"default": 2,
		"min": 1,
		"max": 15,
		"step": 1,
	},
	ORIENTATION: {
		"type": TYPE_INT,
		"default": 0,
		"min": 0,
		"max": 1,
	},
	LAYOUT: {
		"type": TYPE_INT,
		"default": 0,
		"min": 0,
		"max": 1,
	},
	RECTANGLE_WIDTH: {
		"type": TYPE_INT,
		"default": 8,
		"min": 1,
		"max": 50,
		"step": 1,
	},
	RECTANGLE_HEIGHT: {
		"type": TYPE_INT,
		"default": 8,
		"min": 1,
		"max": 50,
		"step": 1,
	},
	SHOW_PATHS: {
		"type": TYPE_BOOL,
		"default": true,
	},
	RAINBOW_PATHS: {
		"type": TYPE_BOOL,
		"default": false,
	},
	COMPLETION_EFFECT: {
		"type": TYPE_BOOL,
		"default": true,
	},
	SHOW_LOOP_ERRORS: {
		"type": TYPE_BOOL,
		"default": true,
	},
	SHOW_ISOLATION_ERRORS: {
		"type": TYPE_BOOL,
		"default": false,
	},
	SHOW_GHOST: {
		"type": TYPE_BOOL,
		"default": true,
	},
	REVIEW_LOCKED: {
		"type": TYPE_BOOL,
		"default": false,
	},
	REVIEW_UNLOCKED: {
		"type": TYPE_BOOL,
		"default": false,
	},
	AUTO_MOVE_SOURCE: {
		"type": TYPE_BOOL,
		"default": false,
	},
	DISABLE_ANIMATION: {
		"type": TYPE_BOOL,
		"default": false,
	},
	EASE_SPEED: {
		"type": TYPE_FLOAT,
		"default": 20.0,
		"min": 10.0,
		"max": 50.0,
		"step": 5.0,
	},
	HOLD_DELAY_MS: {
		"type": TYPE_FLOAT,
		"default": 250.0,
		"min": 200.0,
		"max": 2000.0,
		"step": 1.0,
	},
	WINDOW_SIZE: {
		"type": TYPE_VECTOR2I,
		"default": Vector2i(500, 500),
	},
	WINDOW_MAXIMIZED: {
		"type": TYPE_BOOL,
		"default": false,
	},
}

var _values: Dictionary = {}
var _bound_actions: Dictionary = {}
var _dirty := false
var _syncing_actions := false
var _write_blocked := false
var _save_timer: Timer
var _tracking_window_state := false
var _last_windowed_size := Vector2i(500, 500)
var _last_non_minimized_mode := Window.MODE_WINDOWED


func _ready() -> void:
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY_SECONDS
	_save_timer.timeout.connect(save_now)
	add_child(_save_timer)

	_initialize_values()
	_load_user_settings()
	_setup_window_state()

	get_tree().node_added.connect(_on_node_added)
	for node in get_tree().root.find_children("*", "", true, false):
		_on_node_added(node)

	if OS.has_feature("web") and not is_persistence_available():
		push_warning("Browser storage is unavailable; settings may not persist between sessions")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_capture_window_state()
		save_now()


func _exit_tree() -> void:
	_capture_window_state()
	save_now()


func has_setting(setting_key: StringName) -> bool:
	return DEFINITIONS.has(setting_key)


func get_setting(setting_key: StringName) -> Variant:
	if not has_setting(setting_key):
		push_error("Unknown setting: %s" % setting_key)
		return null
	return _values[setting_key]


func get_bool(setting_key: StringName) -> bool:
	if not _definition_has_type(setting_key, TYPE_BOOL):
		return false
	return _values[setting_key] as bool


func get_int(setting_key: StringName) -> int:
	if not _definition_has_type(setting_key, TYPE_INT):
		return 0
	return _values[setting_key] as int


func get_float(setting_key: StringName) -> float:
	if not _definition_has_type(setting_key, TYPE_FLOAT):
		return 0.0
	return _values[setting_key] as float


func get_vector2i(setting_key: StringName) -> Vector2i:
	if not _definition_has_type(setting_key, TYPE_VECTOR2I):
		return Vector2i.ZERO
	return _values[setting_key] as Vector2i


func set_setting(setting_key: StringName, value: Variant) -> bool:
	if not has_setting(setting_key):
		push_error("Cannot set unknown setting: %s" % setting_key)
		return false

	var sanitized_value: Variant = _sanitize_value(setting_key, value)
	if sanitized_value == null:
		push_warning("Ignoring invalid value for setting: %s" % setting_key)
		return false
	if _values[setting_key] == sanitized_value:
		return true

	_values[setting_key] = sanitized_value
	_sync_bound_actions(setting_key, sanitized_value)
	setting_changed.emit(setting_key, sanitized_value)
	_dirty = true
	if not _write_blocked:
		_save_timer.start()
	return true


func reset_to_defaults() -> void:
	for setting_key: StringName in DEFINITIONS:
		set_setting(setting_key, DEFINITIONS[setting_key]["default"])


func save_now() -> Error:
	if not _dirty:
		return OK
	if _write_blocked:
		return ERR_FILE_UNRECOGNIZED

	var config := ConfigFile.new()
	config.set_value("meta", "version", SETTINGS_VERSION)
	for setting_key: StringName in DEFINITIONS:
		var parts := _split_setting_key(setting_key)
		config.set_value(parts[0], parts[1], _values[setting_key])

	var error := config.save(SETTINGS_PATH)
	if error == OK:
		_dirty = false
	else:
		push_error("Could not save user settings (%s): error %d" % [SETTINGS_PATH, error])
	return error


func is_persistence_available() -> bool:
	return OS.is_userfs_persistent()


func _initialize_values() -> void:
	for setting_key: StringName in DEFINITIONS:
		var parts := _split_setting_key(setting_key)
		if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
			push_error("Setting keys must use the form category/key: %s" % setting_key)
			continue
		_values[setting_key] = DEFINITIONS[setting_key]["default"]


func _load_user_settings() -> void:
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_PATH)
	if error == ERR_FILE_NOT_FOUND:
		_dirty = true
		save_now()
		return
	if error != OK:
		push_warning("Could not load user settings; using defaults (error %d)" % error)
		return

	var file_version: Variant = config.get_value("meta", "version", 0)
	if not file_version is int:
		push_warning("User settings have an invalid version; using defaults")
		return
	if file_version > SETTINGS_VERSION:
		_write_blocked = true
		push_warning("User settings come from a newer version; changes will not be written")
		return

	var needs_upgrade: bool = file_version < SETTINGS_VERSION
	for setting_key: StringName in DEFINITIONS:
		var parts := _split_setting_key(setting_key)
		if not config.has_section_key(parts[0], parts[1]):
			needs_upgrade = true
			continue
		var sanitized_value: Variant = _sanitize_value(
			setting_key,
			config.get_value(parts[0], parts[1])
		)
		if sanitized_value == null:
			needs_upgrade = true
			push_warning("Invalid saved setting ignored: %s" % setting_key)
			continue
		_values[setting_key] = sanitized_value

	if needs_upgrade:
		_dirty = true
		save_now()


func _definition_has_type(setting_key: StringName, expected_type: int) -> bool:
	if not has_setting(setting_key):
		push_error("Unknown setting: %s" % setting_key)
		return false
	var actual_type: int = DEFINITIONS[setting_key]["type"]
	if actual_type != expected_type:
		push_error(
			"Setting %s has type %s, not %s"
			% [setting_key, type_string(actual_type), type_string(expected_type)]
		)
		return false
	return true


func _sanitize_value(setting_key: StringName, value: Variant) -> Variant:
	var definition: Dictionary = DEFINITIONS[setting_key]
	var expected_type: int = definition["type"]
	var sanitized_value: Variant

	match expected_type:
		TYPE_BOOL:
			if not value is bool:
				return null
			sanitized_value = value
		TYPE_INT:
			if not (value is int or value is float):
				return null
			sanitized_value = roundi(float(value))
		TYPE_FLOAT:
			if not (value is int or value is float):
				return null
			sanitized_value = float(value)
		TYPE_STRING:
			if not value is String:
				return null
			sanitized_value = value
		_:
			if typeof(value) != expected_type:
				return null
			sanitized_value = value

	if expected_type == TYPE_INT:
		if definition.has("min"):
			sanitized_value = maxi(sanitized_value, int(definition["min"]))
		if definition.has("max"):
			sanitized_value = mini(sanitized_value, int(definition["max"]))
		if definition.has("step"):
			sanitized_value = snappedi(sanitized_value, int(definition["step"]))
	elif expected_type == TYPE_FLOAT:
		if definition.has("min"):
			sanitized_value = maxf(sanitized_value, float(definition["min"]))
		if definition.has("max"):
			sanitized_value = minf(sanitized_value, float(definition["max"]))
		if definition.has("step"):
			sanitized_value = snappedf(sanitized_value, float(definition["step"]))

	return sanitized_value


func _split_setting_key(setting_key: StringName) -> PackedStringArray:
	return String(setting_key).split("/", false, 1)


func _setup_window_state() -> void:
	if (
		not OS.has_feature("windows")
		or Engine.is_embedded_in_editor()
		or DisplayServer.get_name() == "headless"
	):
		return

	var window := get_window()
	_last_windowed_size = _clamp_window_size(get_vector2i(WINDOW_SIZE), window.current_screen)
	window.mode = Window.MODE_WINDOWED
	window.size = _last_windowed_size
	if get_bool(WINDOW_MAXIMIZED):
		window.mode = Window.MODE_MAXIMIZED
		_last_non_minimized_mode = Window.MODE_MAXIMIZED
	else:
		_last_non_minimized_mode = Window.MODE_WINDOWED

	_tracking_window_state = true
	window.size_changed.connect(_capture_window_state)


func _capture_window_state() -> void:
	if not _tracking_window_state:
		return
	var window := get_window()
	match window.mode:
		Window.MODE_WINDOWED:
			_last_windowed_size = _clamp_window_size(window.size, window.current_screen)
			_last_non_minimized_mode = Window.MODE_WINDOWED
		Window.MODE_MAXIMIZED:
			_last_non_minimized_mode = Window.MODE_MAXIMIZED
		Window.MODE_MINIMIZED:
			pass
		_:
			return

	set_setting(WINDOW_SIZE, _last_windowed_size)
	set_setting(WINDOW_MAXIMIZED, _last_non_minimized_mode == Window.MODE_MAXIMIZED)


func _clamp_window_size(size: Vector2i, screen: int) -> Vector2i:
	var usable_size := DisplayServer.screen_get_usable_rect(screen).size
	if usable_size == Vector2i.ZERO:
		return Vector2i(maxi(size.x, 320), maxi(size.y, 320))
	return Vector2i(
		clampi(size.x, 320, usable_size.x),
		clampi(size.y, 320, usable_size.y)
	)


func _on_node_added(node: Node) -> void:
	if node is ActionBase:
		_bind_action.call_deferred(node)


func _bind_action(action: ActionBase) -> void:
	if not is_instance_valid(action) or not action.is_inside_tree():
		return
	if action.settings_bound or action.setting_key.is_empty():
		return
	if not has_setting(action.setting_key):
		push_error("Unknown setting '%s' on %s" % [action.setting_key, action.get_path()])
		return
	if not _action_matches_definition(action):
		return

	_configure_action(action)
	_set_action_value(action, _values[action.setting_key])
	_connect_action(action)
	action.settings_bound = true

	var references: Array = _bound_actions.get(action.setting_key, [])
	references.append(weakref(action))
	_bound_actions[action.setting_key] = references


func _action_matches_definition(action: ActionBase) -> bool:
	var expected_type: int = DEFINITIONS[action.setting_key]["type"]
	var matches := (
		(action is ActionToggle and expected_type == TYPE_BOOL)
		or (action is ActionNumber and expected_type in [TYPE_INT, TYPE_FLOAT])
		or (action is ActionSelect and expected_type == TYPE_INT)
	)
	if not matches:
		push_error(
			"Control %s does not match type %s for setting %s"
			% [action.get_path(), type_string(expected_type), action.setting_key]
		)
	return matches


func _configure_action(action: ActionBase) -> void:
	if not action is ActionNumber:
		return
	var definition: Dictionary = DEFINITIONS[action.setting_key]
	if definition.has("min"):
		action.min_value = float(definition["min"])
	if definition.has("max"):
		action.max_value = float(definition["max"])
	if definition.has("step"):
		action.step = float(definition["step"])


func _connect_action(action: ActionBase) -> void:
	if action is ActionToggle:
		action.toggled.connect(_on_action_value_changed.bind(action.setting_key))
	elif action is ActionNumber:
		action.value_changed.connect(_on_action_value_changed.bind(action.setting_key))
	elif action is ActionSelect:
		action.item_selected.connect(_on_action_value_changed.bind(action.setting_key))


func _on_action_value_changed(value: Variant, setting_key: StringName) -> void:
	if not _syncing_actions:
		set_setting(setting_key, value)


func _sync_bound_actions(setting_key: StringName, value: Variant) -> void:
	var live_references: Array = []
	for reference: WeakRef in _bound_actions.get(setting_key, []):
		var action: ActionBase = reference.get_ref()
		if not is_instance_valid(action):
			continue
		live_references.append(reference)
		_set_action_value(action, value)
	_bound_actions[setting_key] = live_references


func _set_action_value(action: ActionBase, value: Variant) -> void:
	_syncing_actions = true
	if action is ActionToggle:
		action.button_pressed = value
	elif action is ActionNumber:
		action.value = value
	elif action is ActionSelect:
		var selected_index := int(value)
		if selected_index >= 0 and selected_index < action.item_count:
			action.select(selected_index)
		else:
			push_error(
				"Setting %s selects missing item %d on %s"
				% [action.setting_key, selected_index, action.get_path()]
			)
	_syncing_actions = false
