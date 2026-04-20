#!/usr/bin/env python3
"""Upgrade specific materials in the library to ShaderMaterial variants
that use the procedural shaders under assets/shaders/. Only the
high-traffic surfaces get the treatment; simple accent colors keep
StandardMaterial3D for efficiency.
"""
import os
import hashlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "godot", "assets", "materials")

def uid(name):
    return "c" + hashlib.sha1(name.encode()).hexdigest()[:16]

def write_shader_mat(name, shader_path, params, resource_name=None):
    rn = resource_name or name
    p_lines = "\n".join(
        f"shader_parameter/{k} = {v}" for k, v in params.items())
    body = f'''[gd_resource type="ShaderMaterial" load_steps=2 format=3 uid="uid://{uid(name)}"]

[ext_resource type="Shader" path="{shader_path}" id="1_shader"]

[resource]
resource_name = "{rn}"
shader = ExtResource("1_shader")
{p_lines}
'''
    with open(os.path.join(OUT, f"{name}.tres"), "w") as f:
        f.write(body)

# Terrain variants. base + accent choose hue/brightness.
write_shader_mat("grass_bright", "res://assets/shaders/terrain.gdshader", {
    "base":   "Color(0.42, 0.72, 0.25, 1)",
    "accent": "Color(0.20, 0.46, 0.16, 1)",
    "noise_scale":     "4.5",
    "noise_strength":  "0.6",
    "edge_darken":     "0.3",
})

write_shader_mat("grass_dark", "res://assets/shaders/terrain.gdshader", {
    "base":   "Color(0.20, 0.46, 0.16, 1)",
    "accent": "Color(0.10, 0.28, 0.08, 1)",
    "noise_scale":     "4.0",
    "noise_strength":  "0.55",
    "edge_darken":     "0.35",
})

write_shader_mat("dirt", "res://assets/shaders/terrain.gdshader", {
    "base":   "Color(0.48, 0.32, 0.18, 1)",
    "accent": "Color(0.26, 0.16, 0.08, 1)",
    "noise_scale":     "3.5",
    "noise_strength":  "0.5",
    "edge_darken":     "0.3",
})

write_shader_mat("sand", "res://assets/shaders/terrain.gdshader", {
    "base":   "Color(0.95, 0.82, 0.55, 1)",
    "accent": "Color(0.78, 0.62, 0.35, 1)",
    "noise_scale":     "5.0",
    "noise_strength":  "0.4",
    "edge_darken":     "0.2",
})

write_shader_mat("snow", "res://assets/shaders/terrain.gdshader", {
    "base":   "Color(0.98, 0.98, 1.0, 1)",
    "accent": "Color(0.82, 0.88, 0.95, 1)",
    "noise_scale":     "5.5",
    "noise_strength":  "0.35",
    "edge_darken":     "0.2",
})

# Stone variants with voronoi cracks.
write_shader_mat("stone_grey", "res://assets/shaders/stone.gdshader", {
    "base":  "Color(0.62, 0.64, 0.66, 1)",
    "crack": "Color(0.30, 0.30, 0.33, 1)",
    "cell_size":       "1.1",
    "crack_width":     "0.04",
    "noise_strength":  "0.4",
})

write_shader_mat("stone_dark", "res://assets/shaders/stone.gdshader", {
    "base":  "Color(0.32, 0.34, 0.38, 1)",
    "crack": "Color(0.12, 0.13, 0.15, 1)",
    "cell_size":       "1.4",
    "crack_width":     "0.05",
    "noise_strength":  "0.45",
})

write_shader_mat("stone_mossy", "res://assets/shaders/stone.gdshader", {
    "base":  "Color(0.48, 0.55, 0.40, 1)",
    "crack": "Color(0.20, 0.28, 0.18, 1)",
    "cell_size":       "1.2",
    "crack_width":     "0.05",
    "noise_strength":  "0.5",
})

write_shader_mat("brick_stone", "res://assets/shaders/stone.gdshader", {
    "base":  "Color(0.76, 0.70, 0.60, 1)",
    "crack": "Color(0.40, 0.36, 0.30, 1)",
    "cell_size":       "0.9",
    "crack_width":     "0.06",
    "noise_strength":  "0.3",
})

write_shader_mat("brick_red", "res://assets/shaders/stone.gdshader", {
    "base":  "Color(0.72, 0.30, 0.24, 1)",
    "crack": "Color(0.35, 0.12, 0.08, 1)",
    "cell_size":       "0.6",
    "crack_width":     "0.07",
    "noise_strength":  "0.35",
})

write_shader_mat("basalt", "res://assets/shaders/stone.gdshader", {
    "base":  "Color(0.20, 0.20, 0.24, 1)",
    "crack": "Color(0.05, 0.05, 0.07, 1)",
    "cell_size":       "1.6",
    "crack_width":     "0.05",
    "noise_strength":  "0.5",
})

write_shader_mat("sandstone", "res://assets/shaders/stone.gdshader", {
    "base":  "Color(0.85, 0.70, 0.45, 1)",
    "crack": "Color(0.50, 0.38, 0.22, 1)",
    "cell_size":       "1.3",
    "crack_width":     "0.05",
    "noise_strength":  "0.4",
})

# Wood variants with grain along Y (vertical planks).
write_shader_mat("wood_light", "res://assets/shaders/wood.gdshader", {
    "light":  "Color(0.82, 0.60, 0.36, 1)",
    "dark":   "Color(0.45, 0.28, 0.14, 1)",
    "grain_dir":     "1",
    "grain_density": "10.0",
    "knot_chance":   "0.04",
})

write_shader_mat("wood_dark", "res://assets/shaders/wood.gdshader", {
    "light":  "Color(0.52, 0.34, 0.20, 1)",
    "dark":   "Color(0.24, 0.14, 0.08, 1)",
    "grain_dir":     "1",
    "grain_density": "12.0",
    "knot_chance":   "0.05",
})

write_shader_mat("wood_planks", "res://assets/shaders/wood.gdshader", {
    "light":  "Color(0.68, 0.46, 0.26, 1)",
    "dark":   "Color(0.36, 0.22, 0.12, 1)",
    "grain_dir":     "1",
    "grain_density": "15.0",
    "knot_chance":   "0.06",
})

write_shader_mat("bark", "res://assets/shaders/wood.gdshader", {
    "light":  "Color(0.40, 0.26, 0.16, 1)",
    "dark":   "Color(0.18, 0.10, 0.06, 1)",
    "grain_dir":     "1",
    "grain_density": "20.0",
    "knot_chance":   "0.08",
})

# Water + lava.
write_shader_mat("water_blue", "res://assets/shaders/water.gdshader", {
    "shallow":        "Color(0.42, 0.78, 0.92, 1)",
    "deep":           "Color(0.08, 0.24, 0.55, 1)",
    "alpha_min":      "0.55",
    "alpha_max":      "0.92",
    "ripple_scale":   "2.2",
    "ripple_speed":   "0.6",
    "foam_strength":  "0.30",
})

write_shader_mat("water_deep", "res://assets/shaders/water.gdshader", {
    "shallow":        "Color(0.15, 0.40, 0.62, 1)",
    "deep":           "Color(0.05, 0.12, 0.35, 1)",
    "alpha_min":      "0.72",
    "alpha_max":      "0.95",
    "ripple_scale":   "1.6",
    "ripple_speed":   "0.4",
    "foam_strength":  "0.05",
})

write_shader_mat("lava", "res://assets/shaders/lava.gdshader", {
    "hot":  "Color(1.0, 0.58, 0.10, 1)",
    "cold": "Color(0.50, 0.12, 0.05, 1)",
    "flow_speed":      "0.35",
    "emission_energy": "2.4",
    "crust_scale":     "1.5",
})

write_shader_mat("lava_crust", "res://assets/shaders/lava.gdshader", {
    "hot":  "Color(0.55, 0.16, 0.05, 1)",
    "cold": "Color(0.18, 0.06, 0.03, 1)",
    "flow_speed":      "0.15",
    "emission_energy": "0.8",
    "crust_scale":     "1.2",
})

print("upgraded 20 materials to shader-based")
