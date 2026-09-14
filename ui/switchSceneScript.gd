extends Control

@export var targetScene: PackedScene

func execute()->void:
	get_tree().change_scene_to_packed(targetScene)
	pass