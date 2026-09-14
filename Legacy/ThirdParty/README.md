# ThirdParty

Vendored native libraries, pinned as git submodules.

## glslang + SPIRV-Cross (Mirage Custom shader transpiler)

The Mirage generator's **Custom** type compiles user-supplied Shadertoy-style GLSL
at runtime by transpiling it to Metal: **glslang** (GLSL to SPIR-V) then
**SPIRV-Cross** (SPIR-V to MSL). Both are pinned submodules and built into one
merged static library the Mirage XPC service links.

### First build / clean checkout

```sh
git submodule update --init --recursive        # fetch glslang + SPIRV-Cross
ThirdParty/build-transpiler.sh universal        # -> build/lib/libkktranspiler.a
```

Then build the Mirage **XPC Service** in Xcode as usual. The `build/` output is
git-ignored; re-run the script only when the submodule tags change (or after a
clean). `arm64` / `x86_64` / `universal` (default) select the slices.

The Mirage XPC target's build settings point `LIBRARY_SEARCH_PATHS` /
`HEADER_SEARCH_PATHS` at `ThirdParty/build/{lib,include}` and link
`-lkktranspiler`.

- Bridge: `Mirage/Mirage/Plugin/Render/KKGLSLTranspiler.{h,mm}`
- Pinned versions: glslang `16.3.0`, SPIRV-Cross `vulkan-sdk-1.4.350.1`
- Licenses: see `../THIRD-PARTY-NOTICES.md` (permissive BSD/MIT/Apache-2.0).
