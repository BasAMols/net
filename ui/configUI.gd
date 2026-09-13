class_name ConfigUI
extends CanvasLayer

const SETTINGS_BY_PROPERTY := {
	"value_requireUnique": ["new_game", "unique_solution"],
	"value_wrap": ["new_game", "wrap"],
	"value_radius": ["new_game", "radius"],
	"value_orientation": ["new_game", "orientation"],
	"value_showSpawn": ["visual", "show_paths"],
	"value_showPathRainbow": ["visual", "rainbow_paths"],
	"value_showCompletionRainbow": ["visual", "completion_effect"],
	"value_showLoops": ["visual", "show_loop_errors"],
	"value_showIsolation": ["visual", "show_isolation_errors"],
	"value_showGhost": ["visual", "show_ghost"],
	"value_review": ["visual", "review_locked"],
	"value_reviewAll": ["visual", "review_unlocked"],
	"value_autoSpawn": ["interaction", "auto_move_source"],
	"value_easeSpeed": ["interaction", "ease_speed"],
	"value_hold_delay": ["interaction", "hold_delay_ms"],
}

@export var grid: HexGrid

var value_requireUnique: bool
var value_wrap: bool

var value_orientation: int
var value_layout: int

var value_radius: float
var value_width: float
var value_height: float

var value_hold_delay: float
var value_easeSpeed: float

var value_autoSpawn: bool
var value_showSpawn: bool
var value_showLoops: bool
var value_showIsolation: bool
var value_showGhost: bool
var value_showCompletionRainbow: bool
var value_showPathRainbow: bool
var value_review: bool
var value_reviewAll: bool
var actions: Array[ActionBase]

@export_exp_easing var curve

func getS(s: String)->bool:
	return self['value_'+s]

func generateConfig() -> HexNetGenerator.GenerationParameters:
	var parameters = HexNetGenerator.GenerationParameters.new()

	parameters.layout = value_layout + 1
	parameters.rectangle_mode = HexNetGenerator.RectangleMode.OFFSET_RECTANGLE
	parameters.orientation = value_orientation
	parameters.offset_parity = HexNetGenerator.OffsetParity.ODD
	parameters.require_unique = value_requireUnique

	match value_layout + 1:
		1:
			parameters.wraparound = value_wrap
			parameters.radius = value_radius
		2:
			parameters.wrap_width = value_wrap
			parameters.wrap_height = value_wrap
			parameters.width = value_width
			parameters.height = value_height
	
	return parameters

func _ready() -> void:
	for node in find_children("*", "", true, false):
		if node is ActionBase:
			actions.append(node)

	SettingsStore.setting_changed.connect(_on_stored_setting_changed)
	
	for action in actions:
		if !action.prop or !action.type or action.type == 'base': continue
		_apply_stored_value(action)

		match action.type:
			'button':
				if action.target and action.target != 'self':
					action.pressed.connect(func():
						self[action.target][action.prop].call()
					)
				else: 
					action.pressed.connect(func():
						self[action.prop].call()
					)
			
			'toggle':

				if action.target and action.target != 'self':
					action.toggled.connect(func(v):
						self[action.target][action.prop] = v
					)
					self[action.target][action.prop] = action.button_pressed
				else: 
					action.toggled.connect(func(v):
						self[action.prop] = v
					)
					self[action.prop] = action.button_pressed

				if SETTINGS_BY_PROPERTY.has(action.prop):
					action.toggled.connect(_store_action_value.bind(action.prop))

				action.toggled.emit(action.button_pressed)

			'number':

				if action.target and action.target != 'self':
					action.value_changed.connect(func(v):
						self[action.target][action.prop] = v
					)
					self[action.target][action.prop] = action.value
				else: 
					action.value_changed.connect(func(v):
						self[action.prop] = v
					)
					self[action.prop] = action.value

				if SETTINGS_BY_PROPERTY.has(action.prop):
					action.value_changed.connect(_store_action_value.bind(action.prop))

				action.value_changed.emit(action.value)

			'select':

				if action.target and action.target != 'self':
					action.item_selected.connect(func(v):
						self[action.target][action.prop] = v
					)
					self[action.target][action.prop] = action.selected
				else: 
					action.item_selected.connect(func(v):
						self[action.prop] = v
					)
					self[action.prop] = action.selected

				if SETTINGS_BY_PROPERTY.has(action.prop):
					action.item_selected.connect(_store_action_value.bind(action.prop))
				
				action.item_selected.emit(action.selected)


func _apply_stored_value(action: ActionBase) -> void:
	if not SETTINGS_BY_PROPERTY.has(action.prop):
		return
	var location: Array = SETTINGS_BY_PROPERTY[action.prop]
	var stored_value: Variant = SettingsStore.get_setting(location[0], location[1], null)
	if stored_value == null:
		return
	_set_action_control_value(action, stored_value)


func _store_action_value(value: Variant, property_name: String) -> void:
	var location: Array = SETTINGS_BY_PROPERTY[property_name]
	SettingsStore.set_setting(location[0], location[1], value)


func _on_stored_setting_changed(section: String, key: String, value: Variant) -> void:
	for action in actions:
		if not SETTINGS_BY_PROPERTY.has(action.prop):
			continue
		var location: Array = SETTINGS_BY_PROPERTY[action.prop]
		if location[0] != section or location[1] != key:
			continue
		_set_action_control_value(action, value)
		_apply_action_value(action, value)
		return


func _set_action_control_value(action: ActionBase, value: Variant) -> void:
	match action.type:
		'toggle':
			action.button_pressed = value
		'number':
			action.value = value
		'select':
			action.selected = value


func _apply_action_value(action: ActionBase, value: Variant) -> void:
	if action.target and action.target != 'self':
		self[action.target][action.prop] = value
	else:
		self[action.prop] = value
				
