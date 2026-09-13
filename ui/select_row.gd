@tool
extends Control

@export_category('Select Row')

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

var _values: Array[String] = []
@export var values: Array[String]: 
	get:
		return _values
	set(v):
		_values = v
		if not is_node_ready(): return
		actionSelect.clear()
		for i in v:
			actionSelect.add_item(i)

@export var setting_key: StringName

@export_group('elements')
@export var actionSelect: ActionSelect
@export var labelElement: Label
@export var iconElement: Label
@export var richElement: RichTextLabel


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	richElement.visible = richElement.text.length() > 0

	richElement.text = _tooltip
	richElement.visible = _tooltip.length() > 0

	labelElement.text = _label
	
	iconElement.text = _icon

	actionSelect.clear()
	for i in values:
		actionSelect.add_item(i)

	actionSelect.setting_key = setting_key
