// Original demonstration shader, MIT licensed with this add-on.
#pragma parameter STRENGTH "Scanline strength" 0.25 0.0 0.8 0.05
uniform sampler2D Texture;
uniform vec2 InputSize;
uniform float STRENGTH;
varying vec2 TEX0;
#if defined(VERTEX)
attribute vec2 TexCoord;
attribute vec4 VertexCoord;
uniform mat4 MVPMatrix;
void main() {
    gl_Position = MVPMatrix * VertexCoord;
    TEX0 = TexCoord;
}
#elif defined(FRAGMENT)
void main() {
    vec4 color = texture2D(Texture, TEX0);
    float phase = mod(floor(TEX0.y * InputSize.y), 2.0);
    gl_FragColor = vec4(color.rgb * (1.0 - STRENGTH * phase), color.a);
}
#endif
