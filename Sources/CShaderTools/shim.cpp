// In-process replacement for the glslangValidator / spirv-cross command-line pipeline.
// Option handling mirrors glslang/StandAlone/StandAlone.cpp and SPIRV-Cross/main.cpp exactly, so the
// output is byte-identical to the CLI tools the shader batch was validated with.

#include "shader_tools.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "glslang/Public/ResourceLimits.h"
#include "glslang/Public/ShaderLang.h"
#include "glslang/build_info.h"
#include "SPIRV/GlslangToSpv.h"

// SPIRV-Cross: reuse the CLI's own compile_iteration() (and its option defaults) by including main.cpp
// with its entry point renamed.
#define main spirv_cross_cli_main
#include "main.cpp"
#undef main

namespace {

char *copyString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

std::once_flag glslangInit;

std::string toMSL(const std::vector<uint32_t> &spirv) {
    CLIArguments args;          // same defaults as the CLI
    args.msl = true;            // --msl
    args.msl_version = 20300;   // --msl-version 20300
    args.set_msl_version = true;
    return compile_iteration(args, spirv);
}

std::string toReflection(const std::vector<uint32_t> &spirv) {
    Parser parser(spirv);       // --reflect (format "json")
    parser.parse();
    CompilerReflection compiler(std::move(parser.get_parsed_ir()));
    compiler.set_format("json");
    return compiler.compile();
}

} // namespace

extern "C" WEShaderOutput we_compile_glsl_pair(const char *vertex, const char *fragment) {
    std::call_once(glslangInit, [] { glslang::InitializeProcess(); });
    WEShaderOutput out{};
    std::ostringstream log;

    // -V: Vulkan 1.0 client, input semantics 100, SPIR-V 1.0, SPV + Vulkan rules.
    const EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);
    const EShLanguage stages[2] = { EShLangVertex, EShLangFragment };
    const char *sources[2] = { vertex, fragment };
    const char *names[2] = { "s.vert", "s.frag" };

    glslang::TProgram program;
    std::vector<std::unique_ptr<glslang::TShader>> shaders;
    bool failed = false;
    for (int i = 0; i < 2; i++) {
        auto shader = std::make_unique<glslang::TShader>(stages[i]);
        shader->setStringsWithLengthsAndNames(&sources[i], nullptr, &names[i], 1);
        shader->setAutoMapBindings(true);               // --amb
        shader->setAutoMapLocations(true);              // --aml
        shader->setUniformLocationBase(0);
        shader->setGlobalUniformBlockName("WEUniforms"); // --sdub WEUniforms 0 0 (needs -R)
        shader->setGlobalUniformSet(0);
        shader->setGlobalUniformBinding(0);
        shader->setNanMinMaxClamp(false);
        shader->setEnvInput(glslang::EShSourceGlsl, stages[i], glslang::EShClientVulkan, 100);
        shader->setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
        shader->setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
        shader->setEnvInputVulkanRulesRelaxed();        // -R
        if (!shader->parse(GetDefaultResources(), 100, false, messages)) failed = true;
        const char *info = shader->getInfoLog();
        if (info && *info) log << names[i] << "\n" << info;
        program.addShader(shader.get());
        shaders.push_back(std::move(shader));
    }
    if (!failed && !program.link(messages)) failed = true;   // -l
    if (!failed && !program.mapIO()) failed = true;
    if (const char *info = program.getInfoLog(); info && *info) log << info;

    if (!failed) {
        try {
            std::string results[4];
            for (int i = 0; i < 2; i++) {
                std::vector<unsigned int> spirv;
                spv::SpvBuildLogger logger;
                glslang::SpvOptions options;  // StandAlone defaults without -g / -O
                glslang::GlslangToSpv(*program.getIntermediate(stages[i]), spirv, &logger, &options);
                log << logger.getAllMessages();
                std::vector<uint32_t> words(spirv.begin(), spirv.end());
                results[i * 2] = toMSL(words);
                results[i * 2 + 1] = toReflection(words);
            }
            out.vertex_msl = copyString(results[0]);
            out.vertex_reflection = copyString(results[1]);
            out.fragment_msl = copyString(results[2]);
            out.fragment_reflection = copyString(results[3]);
            out.ok = 1;
        } catch (const std::exception &e) {
            log << "SPIRV-Cross: " << e.what() << "\n";
        }
    } else {
        log << "SPIR-V is not generated for failed compile or link\n";
    }
    out.log = copyString(log.str());
    return out;
}

extern "C" void we_shader_output_free(WEShaderOutput *o) {
    if (!o) return;
    std::free(o->vertex_msl);
    std::free(o->vertex_reflection);
    std::free(o->fragment_msl);
    std::free(o->fragment_reflection);
    std::free(o->log);
    *o = WEShaderOutput{};
}

#define WE_STR2(x) #x
#define WE_STR(x) WE_STR2(x)

extern "C" const char *we_shader_tools_version(void) {
    return "glslang " WE_STR(GLSLANG_VERSION_MAJOR) "." WE_STR(GLSLANG_VERSION_MINOR) "." WE_STR(GLSLANG_VERSION_PATCH)
           "; SPIRV-Cross vulkan-sdk-1.4.363.0";
}
