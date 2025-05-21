class_name PlyFile extends Resource

var size : int
var vertices : PackedFloat32Array
var properties : Array[StringName]
var split : Array[int] # indices where new objects start

const DEFAULT_PROPERTIES : Array[StringName] = [&"x", &"y", &"z", &"nx", &"ny", &"nz", &"f_dc_0", &"f_dc_1", &"f_dc_2", &"f_rest_0", &"f_rest_1", 
&"f_rest_2", &"f_rest_3", &"f_rest_4", &"f_rest_5", &"f_rest_6", &"f_rest_7", &"f_rest_8", &"f_rest_9", &"f_rest_10", &"f_rest_11", 
&"f_rest_12", &"f_rest_13", &"f_rest_14", &"f_rest_15", &"f_rest_16", &"f_rest_17", &"f_rest_18", &"f_rest_19", &"f_rest_20", &"f_rest_21", 
&"f_rest_22", &"f_rest_23", &"f_rest_24", &"f_rest_25", &"f_rest_26", &"f_rest_27", &"f_rest_28", &"f_rest_29", &"f_rest_30", &"f_rest_31", 
&"f_rest_32", &"f_rest_33", &"f_rest_34", &"f_rest_35", &"f_rest_36", &"f_rest_37", &"f_rest_38", &"f_rest_39", &"f_rest_40", &"f_rest_41", 
&"f_rest_42", &"f_rest_43", &"f_rest_44", &"opacity", &"scale_0", &"scale_1", &"scale_2", &"rot_0", &"rot_1", &"rot_2", &"rot_3"]
const DEFAULT_PROP_CNT = len(DEFAULT_PROPERTIES)

func _init(path:='') -> void:
	split = []
	if not path.is_empty(): parse(path)

func parse(path : String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	var line := file.get_line().split(' ')
	while not line[0] == 'end_header':
		line = file.get_line().split(' ')
		match line[0]:
			'format':   file.big_endian = line[1] == 'binary_big_endian'
			'element':  size = int(line[2])
			'property': properties.push_back(line[2])
	vertices = file.get_buffer(size*len(properties) * 4).to_float32_array()
	if properties.hash() != DEFAULT_PROPERTIES.hash():
		var prop_inverse := {}
		for i in properties.size():
			prop_inverse[properties[i]] = i
		var new_vertices := PackedFloat32Array()
		new_vertices.resize(size*DEFAULT_PROP_CNT)
		for i in size:
			for pi in DEFAULT_PROP_CNT:
				new_vertices[i * DEFAULT_PROP_CNT + pi] = vertices[i * len(properties) + prop_inverse[DEFAULT_PROPERTIES[pi]]] if DEFAULT_PROPERTIES[pi] in prop_inverse else 0
		properties = DEFAULT_PROPERTIES.duplicate()
		vertices = new_vertices
	
func get_vertex(index : int) -> Dictionary:
	var start_index := len(properties) * index
	var vertex := {}
	for i in len(properties):
		vertex[properties[i]] = vertices[start_index + i]
	return vertex

static func merge(pc1 : PlyFile, pc2 : PlyFile) -> PlyFile:
	var merged := PlyFile.new()
	merged.size = pc1.size + pc2.size
	assert(pc1.properties.hash() == pc2.properties.hash())
	merged.properties = pc1.properties
	merged.vertices = PackedFloat32Array(pc1.vertices)
	merged.vertices.append_array(pc2.vertices)
	merged.split.append_array(pc1.split)
	merged.split.append(pc1.vertices.size())
	for s in pc2.split:
		merged.split.append(s + pc1.vertices.size())
	return merged

static func load_gaussian_splats(point_cloud : PlyFile, stride : int, device : RenderingDevice, buffer : RID, should_terminate_reference : Array[bool], num_points_loaded : Array[int], callback : Callable):
	const STRUCT_SIZE := 60 # floats
	assert(len(should_terminate_reference) == 1 and len(num_points_loaded) == 1)
	var num_propoerties := len(point_cloud.properties)
	var p := point_cloud.vertices
	var mutex := Mutex.new()
	var task_id = WorkerThreadPool.add_group_task(func(i : int):
		if should_terminate_reference[0]: return
		# We swizzle point data so that it matches the std430 layout struct in our kernels
		var points := PackedFloat32Array(); points.resize(STRUCT_SIZE*stride)
		var tile_size := mini(point_cloud.size - i*stride, stride)
		var creation_time := Time.get_ticks_msec()*1e-3
		for j in tile_size:
			var v := num_propoerties*(i*stride + j) # Vertex index
			var b := j*STRUCT_SIZE                  # Point index
			
			### Position ###
			for k in range(3):  points[b+k+0] = p[v+k+0]
			points[b+3] = creation_time
			
			### 3D Covariance (precomputed) ###
			var scale := Basis.from_scale(Vector3(exp(p[v+0+55]), exp(p[v+1+55]), exp(p[v+2+55])))

			var rotation := Basis(Quaternion(p[v+1+58], p[v+2+58], p[v+3+58], p[v+0+58])).transposed()
			var cov_3d := (scale * rotation).transposed() * (scale * rotation)
			
			# We only store the top triangle of the covariance since the matrix is symmetric!
			points[b+0+4] = cov_3d.x[0]
			points[b+1+4] = cov_3d.y[0]
			points[b+2+4] = cov_3d.z[0]
			points[b+3+4] = cov_3d.y[1]
			points[b+4+4] = cov_3d.z[1]
			points[b+5+4] = cov_3d.z[2]
			
			### Opacity ###
			points[b+6+4] = 1.0 / (1.0 + exp(-p[v+54]))
			
			### ID for differenciating between objects ###
			points[b+11] = 0
			for k in point_cloud.split:
				if v >= k:
					points[b+11] += 1
			
			### Spherical Harmonic Coefficients ###
			for k in range(3): points[b+k+12] = p[v+k+6]
			for k in range(0, 45, 3): 
				points[b+(k+0)+15] = p[v+(k/3+ 0)+9]
				points[b+(k+1)+15] = p[v+(k/3+15)+9]
				points[b+(k+2)+15] = p[v+(k/3+30)+9]
		if should_terminate_reference[0]: return
		device.buffer_update(buffer, i*STRUCT_SIZE*stride * 4, STRUCT_SIZE*tile_size * 4, points.to_byte_array())
		mutex.lock()
		num_points_loaded[0] += tile_size
		mutex.unlock()
		, ceili(point_cloud.size / stride + 1))
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	callback.call()
