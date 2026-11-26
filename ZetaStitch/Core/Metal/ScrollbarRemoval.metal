#include <metal_stdlib>
using namespace metal;

struct ScrollbarUniforms {
    int barX;
    int barY;
    int barWidth;
    int barHeight;
    uint leftPadding;
    uint rightPadding;
};

kernel void scrollBarTransform(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant ScrollbarUniforms &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint texW = inTexture.get_width();
    uint texH = inTexture.get_height();
    if (gid.x >= texW || gid.y >= texH) {
        return;
    }

    int x = int(gid.x);
    int y = int(gid.y);

    float4 orig = inTexture.read(gid);

    int minX = params.barX;
    int maxX = params.barX + params.barWidth;
    int minY = params.barY;
    int maxY = params.barY + params.barHeight;

    if (x < minX || x >= maxX || y < minY || y >= maxY) {
        outTexture.write(orig, gid);
        return;
    }

    int sampleLeftX = max(0, minX - int(params.leftPadding));
    int sampleRightX = min(int(texW) - 1, maxX + int(params.rightPadding));

    float4 leftColor = inTexture.read(uint2(uint(sampleLeftX), gid.y));
    float4 rightColor = inTexture.read(uint2(uint(sampleRightX), gid.y));

    float t = float(x - minX + 1) / float(max(1, params.barWidth + 1));
    float4 interpolated = mix(leftColor, rightColor, t);

    // Subtle 2px vertical cap feathering to eliminate edge artifacts.
    float distTop = float(y - minY);
    float distBot = float(maxY - 1 - y);
    float verticalMask = clamp(min(distTop, distBot) * 0.5 + 0.5, 0.0, 1.0);

    float4 result = mix(orig, interpolated, verticalMask);
    outTexture.write(result, gid);
}
