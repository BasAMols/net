@tool
extends UI_row
class_name  UI_toggle

@export var actionToggle: ActionToggle

func _ready() -> void:
	super._ready()
	actionToggle.setting_key = setting_key