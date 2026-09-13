extends ColorRect
@export var grid: HexGrid

var targetColor: Color = Color('2e3142')
var visual_follow_rate: float = 4

func _ready() -> void:

	grid.validated.connect(func(v):
		targetColor = Color(
			'black'
			if v and SettingsStore.get_bool(SettingsStore.COMPLETION_EFFECT)
			else '333340'
		)
	)

func _process(delta: float) -> void:
	var weight := 1.0 - exp(-visual_follow_rate * delta)

	color = lerp(color, targetColor, weight)
	if targetColor.is_equal_approx(color):
		color = targetColor
