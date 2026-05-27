#version 330 core
//@Name: CompositerFragment.glsl
in vec2 fUv;

out vec4 fragColor;

uniform sampler2DArray layerTextures;
uniform int layerMask;

void main() {
    vec4 compositeColor = vec4(0.0);

    for (int i = 0; i < 16; i++) {
        int mask = 1 << i;
        if ((layerMask & mask) == 0) continue;

        vec4 layerColor = texture(layerTextures, vec3(fUv, i));

        compositeColor.rgb = layerColor.rgb * layerColor.a + compositeColor.rgb * (1.0 - layerColor.a);
        compositeColor.a = layerColor.a + compositeColor.a * (1.0 - layerColor.a);
    }

    fragColor = compositeColor;
}
