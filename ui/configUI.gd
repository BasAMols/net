class_name ConfigUI
extends CanvasLayer

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
	
	for action in actions:
		if !action.prop or !action.type or action.type == 'base': continue

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
				
				action.item_selected.emit(action.selected)
				
