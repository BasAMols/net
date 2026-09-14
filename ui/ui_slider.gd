@tool
extends UI_row
class_name  UI_slider

@export var actionNumber: ActionNumber
@export var valueElement: Label

func _ready() -> void:
	super._ready()
	actionNumber.value_changed.connect(func(v): valueElement.text = str(roundi(v)))
	actionNumber.setting_key = setting_key
	valueElement.text = str(actionNumber.value)
