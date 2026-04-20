// Water surface — scrolling ripples, view-angle Fresnel lightening,
// slight transparency. Intended for a horizontal plane at the water
// surface; also works on cascades.
shader_type spatial;
render_mode diffuse_burley, blend_mix, depth_draw_opaque;

uniform vec3 shallow : source_color = vec3(0.42, 0.78, 0.92);
uniform vec3 deep : source_color = vec3(0.10, 0.28, 0.55);
uniform float alpha_min : hint_range(0.0, 1.0) = 0.55;
uniform float alpha_max : hint_range(0.0, 1.0) = 0.92;
uniform float ripple_scale : hint_range(0.1, 10.0) = 2.0;
uniform float ripple_speed : hint_range(0.0, 4.0) = 0.6;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.25;

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
    float t = TIME * ripple_speed;
    float r1 = noise3(vec3(wp.x * ripple_scale + t, wp.z * ripple_scale - t * 0.7, 0.0));
    float r2 = noise3(vec3(wp.x * ripple_scale * 2.3 - t * 0.5, wp.z * ripple_scale * 1.7 + t, 5.0));
    float ripple = r1 * 0.6 + r2 * 0.4;
    float fres = pow(1.0 - clamp(abs(dot(normalize(NORMAL), VIEW)), 0.0, 1.0), 2.5);
    vec3 col = mix(deep, shallow, ripple * 0.8 + fres * 0.4);
    // Foam flecks where ripples peak.
    float foam = smoothstep(0.82, 0.95, ripple);
    col = mix(col, vec3(1.0), foam * foam_strength);
    ALBEDO = col;
    ALPHA = mix(alpha_min, alpha_max, fres);
    ROUGHNESS = 0.15;
    METALLIC = 0.1;
}
