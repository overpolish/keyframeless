/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// The always-valid fallback shader source, shared by the FCP
// render (Plugin+Render.m) and the inspector mini-viewer
// (MirageMiniViewerRenderer.m). The transpile itself lives in KKGLSLTranspiler;
// the default source is in Constants.h.

#import <Foundation/Foundation.h>

/// The error-pattern shader (animated dark-red hazard stripes) rendered when a
/// user shader fails to transpile/compile. A trivial GLSL body, so it
/// always transpiles.
extern NSString *MirageCustomErrorShaderSource(void);
