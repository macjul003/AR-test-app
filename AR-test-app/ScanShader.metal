#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

[[visible]]
void scanSurface(realitykit::surface_parameters params)
{
    float3 p = params.geometry().world_position();
    float t = params.uniforms().time();
    float4 cam = params.uniforms().custom_parameter(); // xyz = camera position

    // Grid lines every 10 cm on all three axes
    float3 f = abs(fract(p / 0.1) - 0.5);
    float edge = max(max(smoothstep(0.46, 0.5, f.x), smoothstep(0.46, 0.5, f.y)),
                     smoothstep(0.46, 0.5, f.z));

    // Pulse ring expanding outward from the camera every 3 seconds
    float d = distance(p, cam.xyz);
    float ring = smoothstep(0.25, 0.0, abs(d - fmod(t, 3.0) * 2.0));

    float glow = clamp(edge * 0.6 + ring * 0.9 + 0.08, 0.0, 1.0);
    half3 cyan = half3(0.1, 0.8, 1.0);

    params.surface().set_base_color(half3(0));
    params.surface().set_emissive_color(cyan * half(glow));
    params.surface().set_opacity(half(glow));
}
