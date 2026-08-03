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

---

## OpenColorIO Config ACES (Academy Software Foundation)

Mirage Color Transform incorporates camera transfer-curve parameters and gamut matrices from **AcademySoftwareFoundation/OpenColorIO-Config-ACES**, release `v4.0.0`.

- Source: https://github.com/AcademySoftwareFoundation/OpenColorIO-Config-ACES
- Copyright Contributors to the OpenColorIO Project.
- Licensed under the 3-Clause BSD License.

**Modifications:** the relevant CLF parameters and matrices are represented as GLSL functions in Mirage's built-in Color Transform shader; the Python package and CLF files are not shipped.

Copyright Contributors to the OpenColorIO Project.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

---

## Colour (colour-science.org)

Mirage Color Transform's Fujifilm F-Log / F-Log2 and Nikon N-Log curve coefficients are the vendor-published values; **colour-science/colour** was used as an independent cross-check of those coefficients, because the OpenColorIO ACES config above does not carry those two curves.

- Source: https://github.com/colour-science/colour
- Copyright 2013 Colour Developers.
- Licensed under the 3-Clause BSD License (the same text reproduced above).

**Modifications:** none. No Colour code is shipped or linked; only the published curve coefficients are transcribed as GLSL, and the remaining display transfer functions (sRGB, BT.1886, BT.2100 HLG, SMPTE ST 2084) come from those standards directly.
