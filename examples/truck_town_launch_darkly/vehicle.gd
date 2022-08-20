extends VehicleBody

const STEER_SPEED = 1.5
const STEER_LIMIT = 0.4

var steer_target = 0

export var engine_force_value = 40

func _physics_process(delta):
	var steer_speed_variation = LaunchDarklyClientSideSdk.variation("steer-speed", STEER_SPEED)
	var engine_force_variation = LaunchDarklyClientSideSdk.variation("engine-force", engine_force_value)
	var steer_limit_variation = LaunchDarklyClientSideSdk.variation("steer-limit", STEER_LIMIT)
	
	var fwd_mps = transform.basis.xform_inv(linear_velocity).x

	steer_target = Input.get_action_strength("turn_left") - Input.get_action_strength("turn_right")
	steer_target *= steer_limit_variation

	if Input.is_action_pressed("accelerate"):
		# Increase engine force at low speeds to make the initial acceleration faster.
		var speed = linear_velocity.length()
		if speed < 5 and speed != 0:
			engine_force = clamp(engine_force_variation * 5 / speed, 0, 100)
		else:
			engine_force = engine_force_variation
	else:
		engine_force = 0

	if Input.is_action_pressed("reverse"):
		# Increase engine force at low speeds to make the initial acceleration faster.
		if fwd_mps >= -1:
			var speed = linear_velocity.length()
			if speed < 5 and speed != 0:
				engine_force = -clamp(engine_force_variation * 5 / speed, 0, 100)
			else:
				engine_force = -engine_force_variation
		else:
			brake = 1
	else:
		brake = 0.0

	steering = move_toward(steering, steer_target, steer_speed_variation * delta)
