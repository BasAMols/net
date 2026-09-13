class_name ActionBase
extends Control

@export var setting_key: StringName

var settings_bound := false

func setVisibilityByValue(v: Variant, when: Array[Variant], reverse: bool = false) -> void:
    visible = !when.has(v) if reverse else when.has(v)
