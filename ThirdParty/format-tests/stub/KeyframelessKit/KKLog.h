/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// No-op stand-in for the real KeyframelessKit/KKLog.h so the format-test harness
// can compile the shipping KKGLSLFormatter.mm without linking the framework.
#define KKLogInfo(...) ((void)0)
#define KKLogDebug(...) ((void)0)
#define KKLogWarn(...) ((void)0)
#define KKLogError(...) ((void)0)
