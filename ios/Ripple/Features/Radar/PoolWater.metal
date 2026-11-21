#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 홈 수영장 물 (디자인 WaterSurface.tsx의 GLSL 셰이더를 한 줄씩 옮김).
// 좌표 p는 GLSL과 같게 화면 가운데가 원점, y가 위쪽, 세로 길이가 1이다.
// swimmers: [x, y, phase] × N, touches: [x, y, 시작 시각] × N (둘 다 p 좌표계)

static inline float glslMod(float x, float y) { return x - y * floor(x / y); }
static inline float sq(float x) { return x * x; }

static float ringWave(float2 p, float2 origin, float clock, float strength) {
    float d = length(p - origin);
    float age = glslMod(clock, 6.5);
    float front = age * 0.13;
    float envelope = exp(-sq((d - front) * 10.0)) * exp(-age * 0.34)
        * smoothstep(0.0, 0.45, age) * (1.0 - smoothstep(5.5, 6.5, age));
    return sin(d * 48.0 - age * 6.2) * envelope * strength;
}

static float surface(float2 p, float t,
                     device const float *swimmers, int swimmerCount,
                     device const float *touches, int touchCount) {
    float w = sin(p.x * 8.0 + t * 0.32) * cos(p.y * 9.0 - t * 0.26) * 0.014;
    w += sin(p.x * 19.0 + p.y * 12.0 + t * 0.38) * 0.004;
    w += sin(p.x * 38.0 - p.y * 25.0 + t * 0.55) * 0.0015;
    for (int i = 0; i + 2 < swimmerCount; i += 3) {
        float2 s = float2(swimmers[i], swimmers[i + 1]);
        float z = swimmers[i + 2];
        float d = length(p - s);
        float fade = exp(-d * 38.0);
        w += sin(d * 75.0 - t * 2.1 + z) * fade * 0.0012;
        w += ringWave(p, s, t + z * 0.54, 0.0036) * exp(-d * 9.0);
    }
    for (int i = 0; i + 2 < touchCount; i += 3) {
        float age = t - touches[i + 2];
        float d = length(p - float2(touches[i], touches[i + 1]));
        if (age >= 0.0 && age < 6.0) {
            w += sin(d * 52.0 - age * 9.0) * exp(-sq((d - age * 0.16) * 10.0)) * exp(-age * 0.6)
                * smoothstep(0.0, 0.15, age) * 0.009;
        }
    }
    return w;
}

[[ stitchable ]] half4 poolWater(float2 position, SwiftUI::Layer layer, float4 bounds, float time,
                                 device const float *swimmers, int swimmerCount,
                                 device const float *touches, int touchCount,
                                 float3 deep, float3 shallow, float3 highlight) {
    float2 size = bounds.zw;
    float2 uvTop = (position - bounds.xy) / size;
    float2 vUv = float2(uvTop.x, 1.0 - uvTop.y);
    float aspect = size.x / max(size.y, 1.0);
    float2 p = (vUv - 0.5) * float2(aspect, 1.0);
    float t = time;

    float e = 0.002;
    float h = surface(p, t, swimmers, swimmerCount, touches, touchCount);
    float2 slope = float2(
        surface(p + float2(e, 0.0), t, swimmers, swimmerCount, touches, touchCount)
            - surface(p - float2(e, 0.0), t, swimmers, swimmerCount, touches, touchCount),
        surface(p + float2(0.0, e), t, swimmers, swimmerCount, touches, touchCount)
            - surface(p - float2(0.0, e), t, swimmers, swimmerCount, touches, touchCount)) / (2.0 * e);
    float3 normal = normalize(float3(-slope * 0.7, 1.0));
    float3 light = normalize(float3(-0.5, 0.65, 1.2));
    float diffuse = max(dot(normal, light), 0.0);
    float spec = pow(max(dot(reflect(-light, normal), float3(0.0, 0.0, 1.0)), 0.0), 24.0);
    float3 windowLight = normalize(float3(0.3, -0.2, 1.4));
    float softReflection = pow(max(dot(reflect(-windowLight, normal), float3(0.0, 0.0, 1.0)), 0.0), 12.0);
    float broad = pow(max(dot(normal, normalize(float3(0.25, 0.3, 1.0))), 0.0), 8.0);
    float2 q = p + slope * 0.025;
    float reflection = sin(q.x * 5.0 + q.y * 3.0 + t * 0.16) * sin(q.y * 6.0 - q.x * 2.0 - t * 0.12);
    float refractedLight = pow(0.5 + 0.5 * sin(q.x * 18.0 + q.y * 9.0 + sin(q.y * 13.0 - t * 0.25) * 1.8), 6.0);
    float depth = smoothstep(-0.6, 0.7, p.y + h * 3.0);

    // 바닥(타일·인원수)을 물결 기울기만큼 비틀어 읽는다
    float2 floorUv = vUv + slope * 0.026 + float2(sin(p.y * 11.0 + t * 0.4), cos(p.x * 10.0 - t * 0.3)) * 0.002;
    floorUv = clamp(floorUv, 0.001, 0.999);
    float2 samplePos = bounds.xy + float2(floorUv.x, 1.0 - floorUv.y) * size;
    float3 floorColor = float3(layer.sample(samplePos).rgb);

    float3 water = mix(floorColor, mix(deep, shallow, depth * 0.65 + diffuse * 0.2), 0.38);
    float curvature = (surface(p + float2(0.009, 0.0), t, swimmers, swimmerCount, touches, touchCount)
        + surface(p - float2(0.009, 0.0), t, swimmers, swimmerCount, touches, touchCount)
        + surface(p + float2(0.0, 0.009), t, swimmers, swimmerCount, touches, touchCount)
        + surface(p - float2(0.0, 0.009), t, swimmers, swimmerCount, touches, touchCount) - 4.0 * h) * 160.0;
    water = mix(water, deep, clamp(curvature * 0.45, 0.0, 0.14));
    water = mix(water, shallow, clamp(-curvature * 0.55, 0.0, 0.22));
    water = mix(water, highlight, broad * 0.12 + reflection * 0.035);
    water = mix(water, highlight, spec * 0.4 + softReflection * 0.2 + refractedLight * 0.13);
    float fresnel = sq(1.0 - normal.z);
    water = mix(water, highlight, fresnel * 0.28);
    return half4(half3(water), 1.0h);
}
