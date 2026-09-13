@tool
extends Control

@export_category('Toggle Row')

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

@export var setting_key: StringName

@export_group('elements')
@export var actionToggle: ActionToggle
@export var labelElement: Label
@export var iconElement: Label
@export var richElement: RichTextLabel


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	richElement.visible = richElement.text.length() > 0
	actionToggle.setting_key = setting_key

	labelElement.text = _label
	richElement.text = _tooltip
	richElement.visible = _tooltip.length() > 0
	iconElement.text = _icon
