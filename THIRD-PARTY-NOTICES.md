# Third-Party Notices

This product includes third-party software. Their attribution and license terms
are reproduced below, as required by their respective licenses. Add a new
section here for each third-party component you incorporate.

---

## glslang (Khronos Group)

The Shader plugin compiles user-supplied Shadertoy-style GLSL at runtime. GLSL is
parsed and lowered to SPIR-V by **KhronosGroup/glslang**, vendored as a git
submodule (`ThirdParty/glslang`, pinned to tag `16.3.0`) and linked as a static
library into the Shader XPC service.

- Source: https://github.com/KhronosGroup/glslang
- Copyright (c) The Khronos Group Inc., NVIDIA, Google, LunarG, ARM, and others.
- Licensed under a permissive mix of 3-Clause BSD, 2-Clause BSD, MIT, and
  Apache-2.0 (glslang uses its own preprocessor, so the optional GPL-licensed
  Bison grammar skeleton is not built or shipped).

**Modifications:** none to the library source. It is built with `ENABLE_OPT=OFF`
and `ENABLE_HLSL=OFF` and called through its public C interface. The complete,
unmodified license text is reproduced in `ThirdParty/glslang/LICENSE.txt`.

---

## SPIRV-Cross (Khronos Group)

The Shader plugin transpiles the SPIR-V produced by glslang into Metal Shading
Language using **KhronosGroup/SPIRV-Cross**, vendored as a git submodule
(`ThirdParty/SPIRV-Cross`, pinned to tag `vulkan-sdk-1.4.350.1`) and linked as a
static library into the Shader XPC service.

- Source: https://github.com/KhronosGroup/SPIRV-Cross
- Copyright (c) 2015-2021 Arm Limited and contributors.
- Licensed under the Apache License, Version 2.0.

**Modifications:** none to the library source. It is called through its public C
API (`spirv_cross_c.h`) with the MSL backend. The complete, unmodified license
text is reproduced in `ThirdParty/SPIRV-Cross/LICENSE` (Apache-2.0, the same text
already reproduced above for other Apache-2.0 components).
