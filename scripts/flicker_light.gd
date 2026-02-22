extends OmniLight3D

## Flicker Light Controller
## Attach to: FlickerLight (OmniLight3D) inside House
##
## Required child nodes:
##   FlickerLight
##   ├── FlickerTimer     (Timer)  — controls how often a flicker attempt occurs
##   └── FlickerStepTimer (Timer)  — drives rapid energy changes during a flicker sequence


# ── Constants ─────────────────────────────────────────────────────────────────

const BASE_ENERGY: float = 1.2
const MIN_ENERGY:  float = 0.2

const INTERVAL_MIN: float = 3.0   # seconds between flicker attempts
const INTERVAL_MAX: float = 8.0

const FLICKER_CHANCE: float = 0.4  # 40 %

const DURATION_MIN: float = 0.2   # seconds a flicker sequence lasts
const DURATION_MAX: float = 0.5

const STEP_INTERVAL: float = 0.05  # seconds between each energy snap during flicker


# ── Node References ───────────────────────────────────────────────────────────

@onready var _interval_timer: Timer = $FlickerTimer
@onready var _step_timer: Timer     = $FlickerStepTimer


# ── State ─────────────────────────────────────────────────────────────────────

var _is_flickering:    bool  = false
var _flicker_elapsed:  float = 0.0
var _flicker_duration: float = 0.0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	light_energy = BASE_ENERGY

	# FlickerStepTimer — loops at a fixed 0.05 s rate; only runs during a flicker
	_step_timer.wait_time = STEP_INTERVAL
	_step_timer.one_shot  = false
	_step_timer.autostart = false
	_step_timer.timeout.connect(_on_step_timeout)

	# FlickerTimer — one-shot, restarted manually each cycle with a new random delay
	_interval_timer.one_shot  = true
	_interval_timer.autostart = false
	_interval_timer.timeout.connect(_on_interval_timeout)

	_schedule_next_check()


# ── Flicker Logic ─────────────────────────────────────────────────────────────

func _schedule_next_check() -> void:
	_interval_timer.wait_time = randf_range(INTERVAL_MIN, INTERVAL_MAX)
	_interval_timer.start()


func _on_interval_timeout() -> void:
	# Only start a new flicker if one is not already running
	if not _is_flickering and randf() < FLICKER_CHANCE:
		_is_flickering    = true
		_flicker_elapsed  = 0.0
		_flicker_duration = randf_range(DURATION_MIN, DURATION_MAX)
		_step_timer.start()

	_schedule_next_check()


func _on_step_timeout() -> void:
	_flicker_elapsed += STEP_INTERVAL

	if _flicker_elapsed >= _flicker_duration:
		# Sequence complete — restore base energy and unlock for next trigger
		light_energy   = BASE_ENERGY
		_is_flickering = false
		_step_timer.stop()
	else:
		# Snap to a random energy level for this step
		light_energy = randf_range(MIN_ENERGY, BASE_ENERGY)
