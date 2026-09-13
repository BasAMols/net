class_name ActionBase
extends Control

@export var target: String = 'self'
@export var prop: String

func setVisibilityByValue(v: Variant, when: Array[Variant], reverse: bool = false) -> void:
    visible = !when.has(v) if reverse else when.has(v)
