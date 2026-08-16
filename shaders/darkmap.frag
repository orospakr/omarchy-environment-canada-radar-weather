#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float amount;   // 0 = untouched basemap, 1 = full dark filter
};
layout(binding = 1) uniform sampler2D source;

// invert + hue-rotate(180deg): the CSS "dark map" recipe. Inverting alone
// turns lakes brown; the hue flip puts water back to blue and roads to yellow.
const mat3 hue180 = mat3(
    -0.574, 0.426, 0.426,
     1.430, 0.430, 1.430,
     0.144, 0.144, -0.856);

void main() {
    vec4 t = texture(source, qt_TexCoord0);
    vec3 c = t.a > 0.0 ? t.rgb / t.a : vec3(0.0);
    vec3 d = clamp(hue180 * (vec3(1.0) - c), 0.0, 1.0);
    fragColor = vec4(mix(c, d, amount) * t.a, t.a) * qt_Opacity;
}
