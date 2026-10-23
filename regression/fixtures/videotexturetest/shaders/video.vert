attribute vec3 a_Position;
attribute vec2 a_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
varying vec2 v_UV;
void main() {
    gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
    v_UV = a_TexCoord;
}
