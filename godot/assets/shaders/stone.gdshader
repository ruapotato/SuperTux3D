// Stone/brick shader — base color plus a darker crack/mortar pattern
// drawn via world-space voronoi cells. Cracks visually tile faces
// into chunks so a flat wall reads as masonry.
shader_type spatial;
render_mode diffuse_burley, specular_disabled;

uniform vec3 base : source_color = vec3(0.58, 0.60, 0.62);
uniform vec3 crack : source_color = vec3(0.30, 0.30, 0.33);
uniform float cell_size : hint_range(0.3, 4.0) = 1.1;
uniform float crack_width : hint_range(0.0, 0.15) = 0.04;
uniform float noise_strength : hint_range(0.0, 1.0) = 0.35;

float hash(vec3 p) {
    p = fract(p * vec3(443.8975, 397.2973, 491.1871));
    p += dot(p.zyx, p.xyz + 19.27);
    return fract(p.x * p.y * p.z);
}

vec3 hash3(vec3 p) {
    return vec3(hash(p), hash(p + 17.3), hash(p + 31.1));
}

float noise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
            mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
        mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
            mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y),
        f.z);
}

// Voronoi distance-to-second-closest: bright inside each cell, dark on
// the borders. Perfect for mortar lines between irregular bricks.
float voronoi_edge(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    float d1 = 8.0;
    float d2 = 8.0;
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec3 cell = vec3(float(x), float(y), float(z));
                vec3 point = cell + hash3(i + cell);
                float d = distance(f, point);
                if (d < d1) { d2 = d1; d1 = d; }
                else if (d < d2) { d2 = d; }
            }
        }
    }
    return d2 - d1;
}

void fragment() {
    vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float vn = voronoi_edge(wp / cell_size);
    float crack_mask = smoothstep(0.0, crack_width, vn);
    vec3 stone = mix(crack, base, crack_mask);
    float grain = noise3(wp * 4.0);
    stone = mix(stone, stone * (0.85 + grain * 0.3), noise_strength);
    ALBEDO = stone;
    ROUGHNESS = 0.82;
    METALLIC = 0.0;
}
