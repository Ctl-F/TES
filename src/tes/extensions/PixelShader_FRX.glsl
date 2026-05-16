#version 330 core
in vec2 f_Uv;
out vec4 fragColor;

uniform sampler2D PixelBuffer;

void main() {
    vec4 color = texture(PixelBuffer, f_Uv);
    fragColor = color;
}
