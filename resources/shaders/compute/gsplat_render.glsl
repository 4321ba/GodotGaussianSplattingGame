#[compute]
#version 460

#extension GL_KHR_shader_subgroup_arithmetic: enable

#define MIN_FACTOR     (255)
#define MIN_ALPHA      (1.0 / MIN_FACTOR)
#define TILE_SIZE      (16)
#define WORKGROUP_SIZE (TILE_SIZE*TILE_SIZE)

layout (local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 1) in;

struct RasterizeData {
	vec2 image_pos;
    vec2 pos_xy;
	vec3 conic;
	float pos_z;
	vec4 color;
};

layout(std430, set = 0, binding = 0) restrict readonly buffer CulledBuffer {
	RasterizeData culled_buffer[];
};

layout (std430, set = 0, binding = 1) restrict readonly buffer SortBuffer {
    uint sort_buffer[];
};

layout (std430, set = 0, binding = 2) restrict readonly buffer BoundsBuffer {
    uvec2 bounds_buffer[];
};

layout (std430, set = 0, binding = 3) restrict writeonly buffer TargetTileSplatBuffer {
    vec3 splat_pos; // Used only to retrieve the splat position at the cursor's tile.
    float num_tile_splats;
};

layout(rgba32f, set = 0, binding = 4) uniform restrict writeonly image2D rasterized_image;

layout(push_constant) restrict readonly uniform PushConstants {
	float heatmap_factor;
    uint target_tile_id;
};

shared vec3[WORKGROUP_SIZE] conic_tile;
shared vec4[WORKGROUP_SIZE] color_tile;
shared vec2[WORKGROUP_SIZE] image_pos_tile;
shared uint shared_t;

void main() {
    shared_t = ~0; // Initialize shared alpha to MAX_UINT
	const ivec2 dims = imageSize(rasterized_image);
	const uvec2 grid_size = (dims + TILE_SIZE - 1) / TILE_SIZE;
    
    const uvec2 id_block = gl_WorkGroupID.xy;
    const uint id_local = gl_LocalInvocationIndex;
    const uint tile_id = id_block.y*grid_size.x + id_block.x;
    const vec2 image_pos = id_block*TILE_SIZE + gl_LocalInvocationID.xy;

    const uvec2 bounds = bounds_buffer[tile_id];
    const int num_splats = max(0, int(bounds.y - bounds.x));
    const int num_iterations = int(ceil(num_splats / float(WORKGROUP_SIZE)));

    vec3 blended_color = vec3(0.0); //imageLoad(rasterized_image, ivec2(image_pos)).rgb;
    float t = 1.0;
    for (uint i = 0; i < num_iterations && shared_t > MIN_FACTOR; ++i) {
        const uint sort_offset = WORKGROUP_SIZE*i;
        const uint chunk_size = min(WORKGROUP_SIZE, num_splats - sort_offset);

        barrier();
        // Coalesced load of the next tile of data into shared memory.
        RasterizeData data = culled_buffer[sort_buffer[(bounds.x + sort_offset) + id_local]];
        conic_tile[id_local] = data.conic;
        color_tile[id_local] = data.color;
        image_pos_tile[id_local] = data.image_pos;
        shared_t = 0; // Reset shared alpha
        barrier();

        for (uint j = 0; j < chunk_size && t > MIN_ALPHA; ++j) {
            vec3 conic = conic_tile[j];
            vec4 color = color_tile[j];
            vec2 offset = image_pos_tile[j] - image_pos;
            
            float power = -0.5 * (conic.x * offset.x*offset.x + conic.z * offset.y*offset.y) - conic.y * offset.x*offset.y;
            // if (power > 0.0) continue; // Branching is slowwwwww
            float alpha = color.a * exp(power);
            // if (alpha < MIN_ALPHA) continue;

            blended_color += color.rgb * alpha * t;
            t *= (1.0 - alpha);
        }

        // We add up all the alpha across the block; if it is greater than MIN_FACTOR, the
        // alpha of the entire block will be greater than MIN_ALPHA.
        // In such case, some threads still have splats to draw and all threads in the block
        // will continue to loop fetching the remaining splats into shared memory.
        atomicAdd(shared_t, uint(t*MIN_FACTOR));
        barrier();
    }
    vec3 heatmap_color = mix(vec3(0,0,1), vec3(1,0.2,0.2), num_splats*5e-4) * (1.0 - t) * heatmap_factor;
	imageStore(rasterized_image, ivec2(image_pos), vec4(blended_color + heatmap_color, 1.0));

    // Used for when the user selects a tile to move the cursor to. This is not as accurate as checking
    // for the closest splat in the cursor position, but it is much faster.
    if (subgroupElect() && tile_id == target_tile_id && t != 1.0) {
        // roundi(lerpf(bounds[0], bounds[1], 0.1))
        RasterizeData target_data = culled_buffer[sort_buffer[bounds.x + (bounds.y - bounds.x)/10]];
        splat_pos = vec3(target_data.pos_xy, target_data.pos_z);
        num_tile_splats = num_splats;
    }
}