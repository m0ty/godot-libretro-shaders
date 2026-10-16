# Changelog

## 1.0.0

Initial release.

- Load external RetroArch/libretro `.glsl` shaders and `.glslp` presets at runtime through pure GDScript, without native extensions or editor plugin activation.
- Apply CanvasLayer post-processing with up to 16 passes and per-pass sizing.
- Edit shader parameters and configure lookup images and sampler settings.
- Support original-frame inputs, previous-frame history, feedback and GPU mipmaps.
- Render to HDR and sRGB targets.
- Cache translated shaders in bounded memory and optionally profile imports.
- Explore presets and parameters in a standalone synthetic demo with an original
  scanline shader.
- Use included integration and API documentation, compatibility evidence and shader audit tools.
