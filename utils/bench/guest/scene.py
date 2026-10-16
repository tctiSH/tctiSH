"""The scene blender_render renders, run by Blender as `blender -b --python scene.py`.

More than the default cube's one diffuse material: glossy, glass and diffuse
surfaces, a subdivided mesh for BVH work, and a sun. Denoising and adaptive
sampling are off, and the seed is fixed, so the time is Cycles' kernels and
the pixels come out the same on every correct build.

Blender picks Cycles' AVX2 kernel on the app's CPU model (Haswell-v4), so this
is the suite's float and SIMD workload.
"""

import hashlib
import time

import bpy

SAMPLES = 32
WIDTH, HEIGHT = 320, 240

s = bpy.context.scene
s.render.engine = "CYCLES"
s.cycles.device = "CPU"
s.cycles.samples = SAMPLES
s.cycles.use_denoising = False
s.cycles.use_adaptive_sampling = False
s.cycles.seed = 1
s.render.resolution_x, s.render.resolution_y = WIDTH, HEIGHT
s.render.resolution_percentage = 100
s.render.filepath = "/tmp/render.png"
s.render.use_stamp = False


def material(name, **inputs):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    for k, v in inputs.items():
        p.inputs[k].default_value = v
    return m


cube = bpy.data.objects["Cube"]
cube.data.materials.clear()
cube.data.materials.append(
    material("rough", **{"Base Color": (0.8, 0.3, 0.2, 1), "Roughness": 0.6})
)
bpy.ops.mesh.primitive_monkey_add(location=(2.2, 0, 0.3))
monkey = bpy.context.object
monkey.modifiers.new("sub", "SUBSURF").levels = 2
monkey.modifiers["sub"].render_levels = 2
monkey.data.materials.append(
    material("glass", **{"Transmission Weight": 1.0, "Roughness": 0.05, "IOR": 1.45})
)
bpy.ops.mesh.primitive_uv_sphere_add(location=(-2.2, 0, 0), segments=64, ring_count=32)
bpy.context.object.data.materials.append(material("metal", Metallic=1.0, Roughness=0.2))
bpy.ops.mesh.primitive_plane_add(size=20, location=(0, 0, -1))
bpy.context.object.data.materials.append(
    material("floor", **{"Base Color": (0.5, 0.5, 0.5, 1), "Roughness": 0.9})
)
bpy.ops.object.light_add(type="SUN", location=(0, 0, 5))
bpy.context.object.data.energy = 3.0

start = time.time()
bpy.ops.render.render(write_still=True)
print(f"@metric render {time.time() - start:.2f} s", flush=True)

# The PNG differs between identical renders, so digest the pixels themselves.
image = bpy.data.images.load("/tmp/render.png")
pixels = bytes(round(v * 255) for v in image.pixels[:])
print(f"@check pixels {hashlib.md5(pixels).hexdigest()[:12]}", flush=True)
