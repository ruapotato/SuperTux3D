// Generic terrain shader — ground surfaces with color variation from
// world-space noise so the texture reads as organic instead of flat
// paint. One shader covers grass / dirt / sand / snow / rock — the
// `base`, `accent`, and `noise_scale` params shift the palette.
shader_type spatial;
render_mode diffuse_burley, specular_disabled;

uniform vec3 base : source_color = vec3(0.42, 0.72, 0.25);
uniform vec3 accent : source_color = vec3(0.20, 0.46, 0.16);
uniform float noise_scale : hint_range(0.1, 20.0) = 3.0;
uniform float noise_strength : hint_range(0.0, 1.0) = 0.55;
uniform float edge_darken : hint_range(0.0, 1.0) = 0.35;

// Hash-based value noise — cheap, no texture dependency. Smoothed so
// adjacent verts blend cleanly.
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
    float n = noise3(wp * noise_scale) * 0.7
            + noise3(wp * noise_scale * 3.1) * 0.3;
    vec3 col = mix(base, accent, n * noise_strength);
    // Rim/edge darkening from the view angle gives the low-poly shapes
    // visible silhouette depth without a texture.
    float rim = 1.0 - abs(dot(normalize(NORMAL), VIEW));
    col = mix(col, col * (1.0 - edge_darken), rim * rim);
    ALBEDO = col;
    ROUGHNESS = 0.85;
    METALLIC = 0.0;
}
