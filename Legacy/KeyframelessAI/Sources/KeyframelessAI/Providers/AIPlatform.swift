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

	/// Minimum installed RAM to offer local inference. The catalog is all-MoE
	/// (big-model quality at low compute, but ALL experts stay resident ~16 GB),
	/// so 24 GB is the real floor: less than that swaps against FCP. Smaller dense
	/// models were dropped (transform quality wasn't worth it). A hard gate, same
	/// spirit as the Intel gate - under-spec machines use cloud (BYOK) instead;
	/// that's a fundamental limitation of local LLMs, not a bug.
	static let minLocalRAMGB = 24

	/// Whether local inference is offered at all: Apple Silicon AND >= 24 GB RAM.
	static let supportsLocal: Bool = isAppleSilicon && physicalMemoryGB >= minLocalRAMGB
}
