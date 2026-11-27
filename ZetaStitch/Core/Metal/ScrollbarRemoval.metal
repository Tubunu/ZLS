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

    // Average 3 outer background texels on each side to suppress H.264 compression ringing
    // without touching the removed capsule region [minX, maxX).
    int l0 = max(0, min(minX - 1, sampleLeftX - 1));
    int l1 = max(0, min(minX - 1, sampleLeftX));
    int l2 = max(0, min(minX - 1, sampleLeftX + 1));
    float4 leftColor = (inTexture.read(uint2(uint(l0), gid.y))
        + inTexture.read(uint2(uint(l1), gid.y))
        + inTexture.read(uint2(uint(l2), gid.y))) / 3.0;

    int rMaxBound = max(maxX, int(texW) - 1);
    int r0 = min(int(texW) - 1, max(min(maxX, rMaxBound), sampleRightX - 1));
    int r1 = min(int(texW) - 1, max(min(maxX, rMaxBound), sampleRightX));
    int r2 = min(int(texW) - 1, max(min(maxX, rMaxBound), sampleRightX + 1));
    float4 rightColor = (inTexture.read(uint2(uint(r0), gid.y))
        + inTexture.read(uint2(uint(r1), gid.y))
        + inTexture.read(uint2(uint(r2), gid.y))) / 3.0;

    float t = float(x - minX + 1) / float(max(1, params.barWidth + 1));
    float4 interpolated = mix(leftColor, rightColor, t);
    outTexture.write(interpolated, gid);
}
