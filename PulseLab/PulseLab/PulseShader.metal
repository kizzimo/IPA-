#include <metal_stdlib>
using namespace metal;
kernel void pulse_compute(device float *values [[buffer(0)]],
                          uint id [[thread_position_in_grid]]) {
    float x = values[id];
    for (uint n = 0; n < 16; ++n) {
        x = fma(x, 1.000001f, 0.000001f);
    }
    values[id] = x;
}
