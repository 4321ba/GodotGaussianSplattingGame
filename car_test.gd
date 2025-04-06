extends RigidBody3D

# Movement speed and rotation speed
var move_speed : float = 3.0
var rotation_speed : float = 1.0

# Input variables
var move_direction : Vector3 = Vector3.ZERO

# Called every frame to update the physics and movement
func _physics_process(delta):
	# Get input for forward/backward movement
	var move_input = 0.0
	if Input.is_action_pressed("ui_up"):  # Forward
		move_input = -1
	elif Input.is_action_pressed("ui_down"):  # Backward
		move_input = 1

	# Move the rigidbody in the direction it's facing
	var move_direction = transform.basis.z.normalized() * move_input * move_speed
	linear_velocity = Vector3(move_direction.x, linear_velocity.y, move_direction.z)

	# Get input for rotation (left/right)
	if Input.is_action_pressed("ui_left"):  # Rotate left
		rotate_y(rotation_speed * delta)
	if Input.is_action_pressed("ui_right"):  # Rotate right
		rotate_y(-rotation_speed * delta)
