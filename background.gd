extends ColorRect
@export var grid: HexGrid

var targetColor: Color = Color('2e3142')
var visual_follow_rate: float = 4
var _grid_validated := false

func _ready() -> void:
	_grid_validated = grid.isDone
	grid.validated.connect(_on_grid_validated)
	SettingsStore.setting_changed.connect(_on_setting_changed)
	_refresh_target_color()


func _on_grid_validated(validated: bool) -> void:
	_grid_validated = validated
	_refresh_target_color()


func _on_setting_changed(setting_key: StringName, _value: Variant) -> void:
	if setting_key in [
		SettingsStore.COMPLETION_EFFECT,
		SettingsStore.DISABLE_ANIMATION,
	]:
		_refresh_target_color()


func _refresh_target_color() -> void:
	var animations_disabled := SettingsStore.get_bool(SettingsStore.DISABLE_ANIMATION)
	targetColor = Color(
		'black'
		if (
			_grid_validated
			and SettingsStore.get_bool(SettingsStore.COMPLETION_EFFECT)
		)
		else '333340'
	)

	if animations_disabled:
		color = targetColor
		set_process(false)
	else:
		set_process(not targetColor.is_equal_approx(color))

func _process(delta: float) -> void:
	if SettingsStore.get_bool(SettingsStore.DISABLE_ANIMATION):
		_refresh_target_color()
		return

	var weight := 1.0 - exp(-visual_follow_rate * delta)

	color = lerp(color, targetColor, weight)
	if targetColor.is_equal_approx(color):
		color = targetColor
		set_process(false)
