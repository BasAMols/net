extends Node

## Central, platform-independent store for user preferences.
##
## Defaults are read from res://settingsStore.ini. User overrides are written to
## user://settings.cfg, which Godot maps to native app storage or IndexedDB.

signal setting_changed(section: String, key: String, value: Variant)

const DEFAULTS_PATH := "res://settingsStore.ini"
const SETTINGS_PATH := "user://settings.cfg"
const SAVE_DELAY_SECONDS := 0.4

const VALUE_RANGES := {
	"interaction/ease_speed": Vector2(10.0, 50.0),
	"interaction/hold_delay_ms": Vector2(200.0, 2000.0),
	"new_game/radius": Vector2(1.0, 15.0),
	"new_game/orientation": Vector2(0.0, 1.0),
}

var _defaults := ConfigFile.new()
var _values: Dictionary = {}
var _current_version := 1
var _dirty := false
var _save_timer: Timer


func _ready() -> void:
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY_SECONDS
	_save_timer.timeout.connect(save_now)
	add_child(_save_timer)

	_load_defaults()
	_load_user_settings()
	if OS.has_feature("web") and not is_persistence_available():
		push_warning("Browser storage is unavailable; settings may not persist between sessions")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_now()


func _exit_tree() -> void:
	save_now()


func has_setting(section: String, key: String) -> bool:
	return _values.has(section) and (_values[section] as Dictionary).has(key)


func get_setting(section: String, key: String, fallback: Variant = null) -> Variant:
	if not has_setting(section, key):
		return fallback
	return (_values[section] as Dictionary)[key]


func set_setting(section: String, key: String, value: Variant) -> bool:
	if not _has_definition(section, key):
		push_warning("Ignoring unknown setting: %s/%s" % [section, key])
		return false

	var sanitized_value: Variant = _sanitize_value(section, key, value)
	if sanitized_value == null:
		push_warning("Ignoring invalid value for setting: %s/%s" % [section, key])
		return false

	var section_values: Dictionary = _values[section]
	if section_values[key] == sanitized_value:
		return true

	section_values[key] = sanitized_value
	_values[section] = section_values
	_dirty = true
	setting_changed.emit(section, key, sanitized_value)
	_save_timer.start()
	return true


func reset_to_defaults() -> void:
	for section in _defaults.get_sections():
		if section == "meta":
			continue
		for key in _defaults.get_section_keys(section):
			set_setting(section, key, _defaults.get_value(section, key))


func save_now() -> Error:
	if not _dirty:
		return OK

	var config := ConfigFile.new()
	config.set_value("meta", "version", _current_version)
	for section: String in _values:
		var section_values: Dictionary = _values[section]
		for key: String in section_values:
			config.set_value(section, key, section_values[key])

	var error := config.save(SETTINGS_PATH)
	if error == OK:
		_dirty = false
	else:
		push_error("Could not save user settings (%s): error %d" % [SETTINGS_PATH, error])
	return error


func is_persistence_available() -> bool:
	return OS.is_userfs_persistent()


func _load_defaults() -> void:
	var error := _defaults.load(DEFAULTS_PATH)
	if error != OK:
		push_error("Could not load setting defaults (%s): error %d" % [DEFAULTS_PATH, error])
		return

	var version: Variant = _defaults.get_value("meta", "version", 1)
	if version is int:
		_current_version = version

	for section in _defaults.get_sections():
		if section == "meta":
			continue
		var section_values := {}
		for key in _defaults.get_section_keys(section):
			section_values[key] = _defaults.get_value(section, key)
		_values[section] = section_values


func _load_user_settings() -> void:
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_PATH)
	if error == ERR_FILE_NOT_FOUND:
		return
	if error != OK:
		push_warning("Could not load user settings; using defaults (error %d)" % error)
		return

	var file_version: Variant = config.get_value("meta", "version", 0)
	if not file_version is int:
		push_warning("User settings have an invalid version; using defaults")
		return
	if file_version > _current_version:
		push_warning("User settings come from a newer version; using defaults")
		return

	for section in _defaults.get_sections():
		if section == "meta":
			continue
		for key in _defaults.get_section_keys(section):
			if not config.has_section_key(section, key):
				continue
			var sanitized_value: Variant = _sanitize_value(section, key, config.get_value(section, key))
			if sanitized_value == null:
				push_warning("Invalid saved setting ignored: %s/%s" % [section, key])
				continue
			var section_values: Dictionary = _values[section]
			section_values[key] = sanitized_value
			_values[section] = section_values


func _has_definition(section: String, key: String) -> bool:
	return _defaults.has_section_key(section, key)


func _sanitize_value(section: String, key: String, value: Variant) -> Variant:
	var default_value: Variant = _defaults.get_value(section, key, null)
	var sanitized_value: Variant

	match typeof(default_value):
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
			if typeof(value) != typeof(default_value):
				return null
			sanitized_value = value

	var setting_path := "%s/%s" % [section, key]
	if VALUE_RANGES.has(setting_path):
		var value_range: Vector2 = VALUE_RANGES[setting_path]
		if sanitized_value is int:
			sanitized_value = clampi(sanitized_value, roundi(value_range.x), roundi(value_range.y))
		else:
			sanitized_value = clampf(sanitized_value, value_range.x, value_range.y)

	return sanitized_value
