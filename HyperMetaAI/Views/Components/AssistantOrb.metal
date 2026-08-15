#include <metal_stdlib>
using namespace metal;

struct AssistantOrbVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct AssistantOrbUniforms {
    float2 resolution;
    float time;
    uint state;
    float intensity;
    float audioLevel;
    float reducedMotion;
};

vertex AssistantOrbVertexOut assistantOrbVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    AssistantOrbVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

static float3 assistantOrbColors(uint state, bool accent) {
    if (state == 1) return accent ? float3(0.28, 0.88, 0.84) : float3(0.18, 0.62, 1.00);
    if (state == 2) return accent ? float3(0.18, 0.52, 1.00) : float3(0.18, 0.88, 0.82);
    if (state == 3) return accent ? float3(0.67, 0.38, 0.96) : float3(0.28, 0.58, 1.00);
    if (state == 4) return accent ? float3(0.96, 0.38, 0.65) : float3(0.38, 0.64, 1.00);
    if (state == 5) return accent ? float3(0.34, 0.90, 0.72) : float3(0.12, 0.78, 1.00);
    if (state == 6) return accent ? float3(1.00, 0.62, 0.30) : float3(1.00, 0.28, 0.34);
    return accent ? float3(0.62, 0.38, 0.96) : float3(0.20, 0.62, 1.00);
}

fragment float4 assistantOrbFragment(
    AssistantOrbVertexOut in [[stage_in]],
    constant AssistantOrbUniforms &uniforms [[buffer(0)]]
) {
    float2 point = in.uv * 2.0 - 1.0;
    point.x *= uniforms.resolution.x / max(uniforms.resolution.y, 1.0);

    const float motionScale = mix(1.0, 0.08, uniforms.reducedMotion);
    const float stateSpeed = uniforms.state == 3 || uniforms.state == 5 ? 0.70 : 0.48;
    const float time = uniforms.time * stateSpeed * motionScale;
    const float level = smoothstep(0.018, 0.24, uniforms.audioLevel);
    const float energy = 0.72 + uniforms.intensity * 0.28;

    // A single low-frequency current moves the glass without adding a visible texture.
    float2 drift = float2(sin(time * 0.72), cos(time * 0.61)) * 0.012;
    float2 flowingPoint = point - drift;
    float distanceToCenter = length(flowingPoint);
    float angle = atan2(flowingPoint.y, flowingPoint.x);
    float breathing = sin(time * 0.92) * 0.006 + level * 0.018;
    float edgeFlow = sin(angle * 2.0 - time * 0.78) * (0.003 + level * 0.003);
    float radius = 0.515 + breathing + edgeFlow;
    float signedDistance = distanceToCenter - radius;
    float antialias = max(fwidth(signedDistance), 0.0015);

    float body = 1.0 - smoothstep(-antialias, antialias * 1.5, signedDistance);
    float outside = max(signedDistance, 0.0);
    float rim = exp(-abs(signedDistance) * 72.0);
    float innerRim = exp(-abs(signedDistance + 0.024) * 48.0) * body;
    float nearBloom = exp(-outside * 12.0) * (1.0 - body);
    float canvasFade = 1.0 - smoothstep(0.76, 0.96, distanceToCenter);
    float farBloom = exp(-outside * 7.0) * (1.0 - body) * canvasFade;

    float normalizedRadius = clamp(distanceToCenter / max(radius, 0.001), 0.0, 1.0);
    float sphereDepth = sqrt(clamp(1.0 - normalizedRadius * normalizedRadius, 0.0, 1.0));
    float3 normal = normalize(float3(flowingPoint / max(radius, 0.001), sphereDepth));
    float light = max(dot(normal, normalize(float3(-0.34, 0.46, 0.82))), 0.0);
    float fresnel = pow(1.0 - sphereDepth, 2.25);

    float3 baseColor = assistantOrbColors(uniforms.state, false);
    float3 accentColor = assistantOrbColors(uniforms.state, true);

    float colorPhase = sin(angle - time * 0.56 + normalizedRadius * 1.6) * 0.5 + 0.5;
    float3 glassColor = mix(baseColor, accentColor, 0.18 + colorPhase * 0.46);

    // One broad caustic carries the flowing impression while the center stays optically clear.
    float flowAxis = flowingPoint.y
        + sin(flowingPoint.x * 2.2 + time * 0.72) * 0.105
        - sin(time * 0.38) * 0.055;
    float caustic = exp(-flowAxis * flowAxis * 9.0) * body;

    float2 highlightPoint = flowingPoint - float2(-0.18, 0.20);
    float highlight = exp(-(highlightPoint.x * highlightPoint.x * 34.0
        + highlightPoint.y * highlightPoint.y * 54.0)) * body;
    float secondaryHighlight = pow(
        max(dot(normal, normalize(float3(0.48, -0.30, 0.82))), 0.0),
        18.0
    ) * body;

    float bodyAlpha = body * (
        0.075
        + fresnel * 0.30
        + caustic * 0.055
        + highlight * 0.09
    );
    float rimAlpha = rim * (0.24 + energy * 0.20) + innerRim * 0.08;
    float bloomAlpha = nearBloom * (0.07 + uniforms.intensity * 0.07)
        + farBloom * (0.012 + uniforms.intensity * 0.018);
    float alpha = clamp(bodyAlpha + rimAlpha + bloomAlpha, 0.0, 0.74);

    // Premultiplied output preserves a luminous edge without making the glass body opaque.
    float3 premultipliedColor = glassColor * bodyAlpha * (0.28 + light * 0.20);
    premultipliedColor += mix(baseColor, accentColor, colorPhase) * caustic * bodyAlpha * 0.42;
    premultipliedColor += float3(0.84, 0.96, 1.00) * highlight * bodyAlpha * 0.62;
    premultipliedColor += float3(0.70, 0.90, 1.00) * secondaryHighlight * bodyAlpha * 0.30;
    premultipliedColor += mix(baseColor, accentColor, colorPhase) * rimAlpha * energy;
    premultipliedColor += float3(0.90, 0.98, 1.00) * rim * 0.11;
    premultipliedColor += mix(baseColor, accentColor, colorPhase) * bloomAlpha * 0.74;
    premultipliedColor *= 1.0 + level * 0.16;

    return float4(premultipliedColor, alpha);
}
