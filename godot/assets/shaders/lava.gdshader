// Lava — bright emissive base with drifting dark crust patches.
shader_type spatial;
render_mode diffuse_burley, specular_disabled;

uniform vec3 hot : source_color = vec3(1.0, 0.58, 0.10);
uniform vec3 cold : source_color = vec3(0.45, 0.10, 0.05);
uniform float flow_speed : hint_range(0.0, 2.0) = 0.3;
uniform float emission_energy : hint_range(0.0, 6.0) = 2.2;
uniform float crust_scale : hint_range(0.2, 6.0) = 1.6;

float hash(vec3 p) {
    p = fract(p * vec3(443.8975, 397.2973, 491.1871));
    p += dot(p.zyx, p.xyz + 19.27);
    return fract(p.x * p.y * p.z);
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

void fragment() {
    vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float t = TIME * flow_speed;
    float n = noise3(vec3(wp.x * crust_scale + t, wp.y * crust_scale, wp.z * crust_scale - t));
    vec3 col = mix(cold, hot, smoothstep(0.35, 0.7, n));
    ALBEDO = col;
    EMISSION = col * emission_energy;
    ROUGHNESS = 0.7;
    METALLIC = 0.0;
}
