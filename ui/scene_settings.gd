extends Control

func open()-> void:
	visible = true

func close()-> void:
	visible = false

func toggle()-> void:
	visible = !visible