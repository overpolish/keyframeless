/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Darwin
import Foundation

enum AIPlatform {
	/// True on Apple Silicon. Intel has no usable GPU path for MLX (CPU-only is
	/// far too slow for the multi-pass pipeline), and FCP 12 is Apple-Silicon
	/// only anyway.
	static let isAppleSilicon: Bool = {
		var size = 0
		return sysctlbyname("hw.optional.arm64", nil, &size, nil, 0) == 0
	}()

	/// Installed physical RAM in whole GB.
	static let physicalMemoryGB: Int = Int(
		ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

	/// Whether local inference is offered at all: Apple Silicon AND >=16 GB RAM.
	/// Below 16 GB the smallest worthwhile model (Qwen 9B) leaves no headroom for
	/// FCP and the quality isn't worth it - those users get the cloud (BYOK)
	/// providers instead.
	static let supportsLocal: Bool = isAppleSilicon && physicalMemoryGB >= 16
}
