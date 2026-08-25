#version 440

// Round-capped ring segment, drawn as a signed-distance field.
// One quad, one draw call; changing the sweep is a uniform write, so an
// animated arc costs no geometry rebuild at all.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;      // required by Qt Quick
    float qt_Opacity;     // required by Qt Quick
    vec4  arcColor;       // premultiplied by Qt for a QML `color` property
    vec2  size;           // item size, px
    float radius;         // ring centre-line radius, px
    float halfWidth;      // half the stroke width, px
    float startAngle;     // radians, 0 = +x, growing clockwise on screen
    float sweep;          // radians, >= 0
    float feather;        // antialias half-width, px (1.0 is right at dpr 1..2)
};

const float TAU = 6.28318530718;

void main() {
    // Item-local pixels, origin at the centre. y already grows downward,
    // so angles measured with atan(p.y, p.x) grow clockwise on screen.
    vec2 p = (qt_TexCoord0 - 0.5) * size;
    float r = length(p);

    float a   = atan(p.y, p.x);
    float rel = mod(a - startAngle, TAU);

    float d;
    if (rel <= sweep) {
        // Inside the swept wedge: distance to the ring's centre line.
        d = abs(r - radius) - halfWidth;
    } else {
        // Outside it: distance to whichever round cap is nearer.
        vec2 c0 = radius * vec2(cos(startAngle), sin(startAngle));
        vec2 c1 = radius * vec2(cos(startAngle + sweep), sin(startAngle + sweep));
        d = min(length(p - c0), length(p - c1)) - halfWidth;
    }

    float cov = 1.0 - smoothstep(-feather, feather, d);
    fragColor = arcColor * cov * qt_Opacity;
}
