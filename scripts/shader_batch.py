#!/usr/bin/env python3
"""Batch feasibility test: WE GLSL -> SPIR-V (glslang) -> MSL (SPIRV-Cross).

Preprocessing mirrors linux-wallpaperengine's ShaderUnit (compat macro header, include hoisting,
[COMBO] defaults, gl_FragColor rename). Each vert/frag pair in a directory is compiled per stage;
MSL is then optionally compiled for real by `metalcheck` (Metal runtime).

usage: shader_batch.py <samples_dir> <out_dir> [--variant default|allon]
"""
import hashlib, json, os, re, subprocess, sys
from collections import Counter, defaultdict

HEADER = """#version 330
precision highp float;
#define mul(x, y) ((y) * (x))
#define max(x, y) max (y, x)
#define lerp mix
#define frac fract
#define CAST2(x) (vec2(x))
#define CAST3(x) (vec3(x))
#define CAST4(x) (vec4(x))
#define CAST3X3(x) (mat3(x))
#define float2 vec2
#define float3 vec3
#define float4 vec4
#define int2 ivec2
#define int3 ivec3
#define int4 ivec4
#define saturate(x) (clamp(x, 0.0, 1.0))
#define texSample2D texture
#define texSample2DLod textureLod
#define log10(x) (log2(x) * 0.301029995663981)
#define atan2 atan
#define fmod(x, y) ((x)-(y)*trunc((x)/(y)))
#define ddx dFdx
#define ddy(x) dFdy(-(x))
#define GLSL 1
#define CASTF(x) (float(x))
#define sampler2DBackBuffer sampler2D
#define texSample2DBackBuffer(t, uv, res) texture(t, uv)
#define sampler2DComparison sampler2DShadow
"""
# runtime-provided constants (real values come from the renderer), unless the shader defines them
RUNTIME_DEFAULTS = {"INSTANCECOUNT": 1, "BLENDROWCOUNT": 1}
# WE's compiler accepts HLSL-style scalar broadcast (pow(vec3, float), max(float, vec2)...).
# A user overload would hide the GLSL built-ins, so route through WE_* wrappers instead.
def _compat_funcs():
    out = []
    for t, sc in (("float", "float"), ("vec2", "float"), ("vec3", "float"), ("vec4", "float"),
                  ("int", "int"), ("ivec2", "int"), ("ivec3", "int"), ("ivec4", "int")):
        for fn in ("max", "min"):
            out.append(f"{t} WE_{fn}({t} a, {t} b) {{ return {fn}(a, b); }}")
            if t != sc:
                out.append(f"{t} WE_{fn}({t} a, {sc} b) {{ return {fn}(a, {t}(b)); }}")
                out.append(f"{t} WE_{fn}({sc} a, {t} b) {{ return {fn}({t}(a), b); }}")
        if sc == "float":
            out.append(f"{t} WE_pow({t} a, {t} b) {{ return pow(a, b); }}")
            if t != sc:
                out.append(f"{t} WE_pow({t} a, float b) {{ return pow(a, {t}(b)); }}")
    return "\n".join(out) + "\n#define pow WE_pow\n#define min WE_min\n"
COMPAT_FUNCS = _compat_funcs()
HEADER = HEADER.replace("#define max(x, y) max (y, x)", "#define max(x, y) WE_max (y, x)")
HEADER = HEADER.replace("#define mul", COMPAT_FUNCS + "#define mul", 1)

FRAG_DEFS = "out vec4 out_FragColor;\n#define varying in\n"
VERT_DEFS = "#extension GL_ARB_shader_viewport_layer_array : enable\n#define attribute in\n#define varying out\n"
LIGHTING_V1 = """vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewDir,
    vec3 specularTint, vec3 baseReflectance, float roughness, float metallic) { return vec3(0.0); }
"""

# Metal has a top-left texture origin like D3D: keep WE's HLSL-only screen-space y flips.
Y_FLIP_RE = re.compile(r'^[ \t]*#ifdef HLSL[ \t]*\n([ \t]*[\w.]+\.y\s*=\s*-[\w.]+\.y\s*;[ \t]*)\n[ \t]*#endif', re.M)
INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"', re.M)
COMBO_RE = re.compile(r'//\s*\[COMBO\]\s*(\{.*\})')
UNIFORM_COMBO_RE = re.compile(r'^\s*uniform\s+\w+\s+\w+\s*;\s*//\s*(\{.*\})\s*$', re.M)


def read_include(name, search, seen):
    for d in search:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            if p in seen:
                return ""
            seen.add(p)
            src = open(p, encoding="utf-8", errors="replace").read()
            # nested includes are expanded in place (as LWE does for m_includes)
            return INCLUDE_RE.sub(lambda m: read_include(m.group(1), search, seen), src)
    return f"// include {name} not found\n"


FUNC_DEF_RE = re.compile(r'^[A-Za-z_]\w*(\s+[A-Za-z_]\w*)+\s*\([^;]*$')


def hoist_includes(src, includes):
    """Insert `includes` before the first top-level function definition (helpers may call
    include functions; includes may reference uniforms declared above), moved above any
    enclosing #if block."""
    lines = src.split("\n")
    main_idx = next((i for i, l in enumerate(lines)
                     if FUNC_DEF_RE.match(l) and not l.lstrip().startswith(("uniform", "return", "else"))), None)
    if main_idx is None:
        return None
    stack = []
    for i in range(main_idx):
        s = lines[i].strip()
        if s.startswith("#if"):
            stack.append(i)
        elif s.startswith("#endif") and stack:
            stack.pop()
    at = stack[0] if stack else main_idx
    return "\n".join(lines[:at] + [includes] + lines[at:])


def combos(src, variant):
    out = {}
    for m in COMBO_RE.finditer(src):
        try:
            j = json.loads(m.group(1))
        except Exception:
            continue
        c = j.get("combo")
        if not c:
            continue
        d = j.get("default", 0)
        out[c.upper()] = (1 if variant == "allon" else int(d) if isinstance(d, (int, float)) else 0)
    # sampler-linked combos (e.g. NORMALMAP): default off unless allon
    for m in UNIFORM_COMBO_RE.finditer(src):
        try:
            j = json.loads(m.group(1))
        except Exception:
            continue
        c = j.get("combo")
        if isinstance(c, str) and variant == "allon":
            out.setdefault(c.upper(), 1)
    # texture format combos (TEXnFORMAT) for samplers marked "formatcombo"
    for m in re.finditer(r'uniform\s+sampler2D\w*\s+g_Texture(\d+)\s*;\s*//\s*(\{.*\})', src):
        if '"formatcombo":true' in m.group(2).replace(" ", ""):
            out.setdefault(f"TEX{m.group(1)}FORMAT", 0)
    return out


def preprocess(path, stage, assets_shaders, variant):
    src = open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
    search = [os.path.dirname(path), assets_shaders]
    seen = set()
    inc = ""
    for m in INCLUDE_RE.finditer(src):
        inc += read_include(m.group(1), search, seen) + "\n"
    src = INCLUDE_RE.sub(lambda m: "// " + m.group(0).strip(), src)
    src = re.sub(r'^\s*#require\s+LightingV1\s*$', LIGHTING_V1, src, flags=re.M)
    if inc:
        hoisted = hoist_includes(src, inc)
        if hoisted is None:
            return None, {}
        src = hoisted
    src = Y_FLIP_RE.sub(r"\1", src)
    inc = Y_FLIP_RE.sub(r"\1", inc)
    src = src.replace("gl_FragColor", "out_FragColor")
    src = re.sub(r'^\s*(in|out)\s+uint\s+gl_(InstanceID|ViewportIndex)\s*;', '', src, flags=re.M)
    cs = combos(inc + src, variant)
    for k, v in RUNTIME_DEFAULTS.items():
        if re.search(rf'\b{k}\b', src) and not re.search(rf'#define\s+{k}\b', inc + src):
            cs.setdefault(k, v)
    defs = "".join(f"#define {k} {v}\n" for k, v in sorted(cs.items()))
    return HEADER + (FRAG_DEFS if stage == "frag" else VERT_DEFS) + defs + src, cs


PARAM_RE = re.compile(r'thread const ([\w:<>, ]+?)& (\w+)(?=[,)])')


def fix_msl(path):
    """SPIRV-Cross forwards globals to helper functions as `thread const T&`, which cannot bind
    to uniforms living in `constant`. Pass those by value instead (read-only, so equivalent)."""
    src = open(path).read()
    out = []
    for line in src.split("\n"):
        if not line.startswith((" ", "\t", "#", "struct", "template", "fragment", "vertex", "kernel")) \
                and "(" in line and "thread const" in line:
            line = PARAM_RE.sub(r'\1 \2', line)
        out.append(line)
    open(path, "w").write("\n".join(out))


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr)


def first_error(log):
    for l in log.splitlines():
        if "ERROR" in l or "error" in l:
            return re.sub(r'^.*?ERROR:\s*(\S+:\d+:\s*)?', '', l).strip()[:140]
    return log.strip().splitlines()[-1][:140] if log.strip() else "?"


def main():
    samples, out = sys.argv[1], sys.argv[2]
    variant = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == "--variant" else "default"
    assets_shaders = os.path.join(samples, "wallpaper_engine/assets/shaders")
    os.makedirs(out, exist_ok=True)

    files = []
    for root, _, names in os.walk(samples):
        for n in names:
            if n.endswith((".vert", ".frag")):
                files.append(os.path.join(root, n))
    # dedupe by content+include-dir context (identical copies in preview/ etc.)
    uniq, seen = [], set()
    for f in sorted(files):
        h = hashlib.md5(open(f, "rb").read() + f.encode().split(b"/shaders")[0][-0:]).hexdigest()
        h = hashlib.md5(open(f, "rb").read()).hexdigest() + os.path.splitext(f)[1]
        if h in seen:
            continue
        seen.add(h)
        uniq.append(f)

    results = []
    for f in uniq:
        stage = "frag" if f.endswith(".frag") else "vert"
        rel = os.path.relpath(f, samples)
        key = hashlib.md5(rel.encode()).hexdigest()[:10] + "_" + os.path.basename(f).replace(".", "_")
        rec = {"file": rel, "stage": stage}
        try:
            src, cs = preprocess(f, stage, assets_shaders, variant)
        except Exception as e:
            src, cs = None, {}
            rec["error"] = f"preprocess: {e}"
        if src is None:
            rec.setdefault("error", "preprocess: no main()")
            rec["step"] = "preprocess"
            results.append(rec)
            continue
        glsl = os.path.join(out, key + "." + stage)
        spv = os.path.join(out, key + ".spv")
        msl = os.path.join(out, key + ".metal")
        open(glsl, "w").write(src)
        # Vulkan + relaxed rules: loose uniforms go into ONE default uniform block (one Metal
        # buffer) instead of one buffer per uniform, which overflows Metal's 31-buffer limit.
        code, log = run(["glslangValidator", "-V", "-R", "--sdub", "WEUniforms", "0", "0",
                         "--aml", "--amb", "-S", stage, glsl, "-o", spv])
        if code != 0:
            rec.update(step="glslang", error=first_error(log), glsl=glsl)
            results.append(rec)
            continue
        code, log = run(["spirv-cross", spv, "--msl", "--msl-version", "20300", "--output", msl])
        if code != 0:
            rec.update(step="spirv-cross", error=first_error(log), glsl=glsl)
            results.append(rec)
            continue
        fix_msl(msl)
        rec.update(step="ok", msl=msl, glsl=glsl)
        results.append(rec)

    metalcheck = os.path.join(os.path.dirname(__file__), "../.build/release/metalcheck")
    oks = [r for r in results if r["step"] == "ok"]
    if os.path.exists(metalcheck) and oks:
        _, log = run([metalcheck] + [r["msl"] for r in oks])
        fails = {}
        for l in log.splitlines():
            if l.startswith("FAIL "):
                p, _, e = l[5:].partition("\t")
                fails[p] = re.sub(r'^.*?error: ', '', e)
        for r in oks:
            if r["msl"] in fails:
                r.update(step="metal", error=fails[r["msl"]])

    json.dump(results, open(os.path.join(out, "results.json"), "w"), indent=1)
    by_step = Counter(r["step"] for r in results)
    print(f"variant={variant} unique shaders={len(results)} (of {len(files)} files)")
    print("by step:", dict(by_step))
    errs = Counter((r["step"], r["error"]) for r in results if r["step"] != "ok")
    for (step, e), n in errs.most_common(25):
        print(f"  {n:3d}  [{step}] {e}")


if __name__ == "__main__":
    main()
