@tool
extends Control

@export_category('Slider Row')

var _label: String = ''
@export var label: String: 
	get:
		return _label
	set(v):
		_label = v
		name = v
		if not is_node_ready(): return
		labelElement.text = v

var _icon: String = ''
@export var icon: String: 
	get:
		return _icon
	set(v):
		_icon = v
		if not is_node_ready(): return
		iconElement.text = v

var _tooltip: String = ''
@export_multiline var tooltip: String: 
	get:
		return _tooltip
	set(v):
		_tooltip = v
		if not is_node_ready(): return
		richElement.text = v
		richElement.visible = tooltip.length() > 0

var _state: float = 0.0
@export var state: float: 
	get:
		return _state
	set(v):
		_state = v
		if not is_node_ready(): return
		actionNumber.value = v

@export var target: String
@export var prop: String
@export var minValue: float
@export var maxValue: float
@export var stepValue: float

@export_group('elements')
@export var actionNumber: ActionNumber
@export var labelElement: Label
@export var iconElement: Label
@export var richElement: RichTextLabel
@export var valueElement: Label


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	richElement.visible = richElement.text.length() > 0

	richElement.text = _tooltip
	richElement.visible = _tooltip.length() > 0

	labelElement.text = _label

	iconElement.text = _icon

	actionNumber.min_value = minValue
	actionNumber.max_value = maxValue
	actionNumber.step = stepValue
	actionNumber.value = _state
	actionNumber.value_changed.connect(func(v): valueElement.text = str(roundi(v)))
	actionNumber.target = target
	actionNumber.prop = prop
	actionNumber.value_changed.emit(_state)

	valueElement.text = str(actionNumber.value)
