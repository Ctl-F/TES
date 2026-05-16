#version 330 core
layout(location = 0) in vec2 v_Position;
layout(location = 1) in vec2 v_Uv;

out vec2 f_Uv;

void main() {
    gl_Position = vec4(v_Position, 0, 1);
    f_Uv = v_Uv;
}
