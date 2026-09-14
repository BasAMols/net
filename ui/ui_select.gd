@tool
extends UI_row
class_name  UI_select

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

@export var actionSelect: ActionSelect

func _ready() -> void:

	actionSelect.clear()
	for i in values:
		actionSelect.add_item(i)

	actionSelect.setting_key = setting_key
