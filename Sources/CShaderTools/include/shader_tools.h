#ifndef WE_SHADER_TOOLS_H
#define WE_SHADER_TOOLS_H

#ifdef __cplusplus
extern "C" {
#endif

/// Result of compiling a linked vertex/fragment GLSL pair. Strings are malloc'ed (NULL on failure);
/// release with we_shader_output_free.
typedef struct WEShaderOutput {
    int ok;
    char *vertex_msl;
    char *vertex_reflection;   // SPIRV-Cross JSON reflection
    char *fragment_msl;
    char *fragment_reflection;
    char *log;                 // glslang / SPIRV-Cross diagnostics
} WEShaderOutput;

/// GLSL → SPIR-V (glslang) → MSL 2.3 + JSON reflection (SPIRV-Cross), in-process.
/// Equivalent to the command-line pipeline
///   glslangValidator -V -R --sdub WEUniforms 0 0 --aml --amb -l s.vert s.frag
///   spirv-cross <stage>.spv --msl --msl-version 20300 ; spirv-cross <stage>.spv --reflect
/// Thread-safe.
WEShaderOutput we_compile_glsl_pair(const char *vertex, const char *fragment);

void we_shader_output_free(WEShaderOutput *output);

/// Versions of the linked libraries, e.g. "glslang 16.6.0; SPIRV-Cross vulkan-sdk-1.4.363.0".
const char *we_shader_tools_version(void);

#ifdef __cplusplus
}
#endif

#endif
