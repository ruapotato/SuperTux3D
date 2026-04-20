// Wood shader — streaks of grain along one world axis, plus knots.
// The `grain_dir` param chooses whether rings run along X, Y, or Z.
shader_type spatial;
render_mode diffuse_burley, specular_disabled;

uniform vec3 light : source_color = vec3(0.78, 0.55, 0.32);
uniform vec3 dark : source_color = vec3(0.45, 0.28, 0.14);
uniform int grain_dir : hint_range(0, 2) = 1;  // 0=X, 1=Y, 2=Z
uniform float grain_density : hint_range(1.0, 30.0) = 9.0;
uniform float knot_chance : hint_range(0.0, 0.2) = 0.04;

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
    // Pick the grain axis coordinate.
    float along = (grain_dir == 0) ? wp.x : ((grain_dir == 1) ? wp.y : wp.z);
    // Stripe frequency + sub-noise to break up regularity.
    float stripe = 0.5 + 0.5 * sin(along * grain_density
        + noise3(wp * 0.7) * 3.14);
    vec3 col = mix(dark, light, stripe);
    // Knot: a dark spot where a second noise spikes.
    float n2 = noise3(wp * 2.1);
    if (n2 > 1.0 - knot_chance) {
        col = mix(col, dark * 0.6, smoothstep(1.0 - knot_chance, 1.0, n2));
    }
    ALBEDO = col;
    ROUGHNESS = 0.72;
    METALLIC = 0.0;
}
