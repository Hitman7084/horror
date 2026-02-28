extends Node3D

## Handheld Torch — embers, wind-reactive flame, enhanced flicker
##
## Required child nodes (configured in editor with materials + draw passes):
##   Torch (Node3D)           ← attach this script
##   ├── TorchLight           (OmniLight3D)
##   ├── FlameParticles       (GPUParticles3D)  — needs ParticleProcessMaterial + QuadMesh draw pass
##   └── EmberParticles       (GPUParticles3D)  — needs ParticleProcessMaterial + QuadMesh draw pass


# ── Node References ──────────────────────────────────────────────────────────

@onready var light: OmniLight3D = $TorchLight
@onready var flame_particles: GPUParticles3D = $FlameParticles
@onready var ember_particles: GPUParticles3D = $EmberParticles


# ── State ────────────────────────────────────────────────────────────────────

var is_active := true

# Wind
var wind_direction := Vector3.ZERO
var wind_strength := 0.0

# Flicker
var flicker_time := 0.0


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Make flame material unique so wind changes don't bleed across instances
	if flame_particles.process_material:
		flame_particles.process_material = flame_particles.process_material.duplicate()


func _process(delta: float) -> void:
	if not is_active:
		return

	# ── Slowly vary wind (simulated indoor drift) ──
	wind_direction.x = sin(Time.get_ticks_msec() * 0.0007)
	wind_direction.z = cos(Time.get_ticks_msec() * 0.0005)
	wind_strength = 0.3 + abs(sin(Time.get_ticks_msec() * 0.0003)) * 0.5

	# Apply wind tilt to flame particles
	if flame_particles.process_material:
		flame_particles.process_material.direction = Vector3(0, 1, 0) + wind_direction * wind_strength

	# Slight light sway from wind
	light.position.x = wind_direction.x * 0.02
	light.position.z = wind_direction.z * 0.02

	# ── Enhanced flicker (smooth noise) ──
	flicker_time += delta * 8.0
	var flicker := sin(flicker_time) * 0.6
	var random_noise := randf() * 0.4
	light.light_energy = 3.5 + flicker + random_noise


## Toggle torch on/off. Call from any external system.
func toggle() -> void:
	is_active = !is_active
	light.visible = is_active
	flame_particles.emitting = is_active
	ember_particles.emitting = is_active
