/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

extension AIPluginAgent {
	static let curveCode: [String: Int] = [
		"linear": 0, "easein": 1, "easeout": 2, "easeinout": 3,
		"elastic": 4, "bounce": 5,
	]

	static let modulationCode: [String: Int] = [
		"none": 0, "wiggle": 1, "oscillate": 2, "handheld": 3,
	]

	static let curveNameByCode: [Int: String] = [
		0: "linear", 1: "easeIn", 2: "easeOut", 3: "easeInOut",
		4: "elastic", 5: "bounce",
	]

	static let modulationNameByCode: [Int: String] = [
		0: "none", 1: "wiggle", 2: "oscillate", 3: "handheld",
	]

	static func buildOperationJSON(
		timingOp: TimingOperation,
		values: [[Double]],
		styles: [StyleChoice],
		existingKeyposes: [(time: Double, values: [Double])],
		existingIntervals: [(start: Double, end: Double, curve: String, modulation: String)]
	) -> [String: Any] {
		var effectiveValues = interleaveValues(
			keyposes: timingOp.keyposes,
			newValues: values,
			existingKeyposes: existingKeyposes)
		enforceHoldInvariant(keyposes: timingOp.keyposes, values: &effectiveValues)

		var kps: [[String: Any]] = []
		for (i, kp) in timingOp.keyposes.enumerated() {
			let vals = i < effectiveValues.count ? effectiveValues[i] : []
			var entry: [String: Any] = [
				"time": kp.time,
				"values": vals,
			]
			let kind = kp.intervalKind.lowercased()
			let isLast = i == timingOp.keyposes.count - 1
			if isLast || kind == "none" {
				entry["outgoing"] = NSNull()
			} else {
				let style = resolveStyle(
					at: i, in: timingOp.keyposes,
					styles: styles, existingIntervals: existingIntervals)
				entry["outgoing"] = encodeOutgoing(kind: kind, style: style)
			}
			kps.append(entry)
		}
		return [
			"lane": timingOp.lane,
			"keyposes": kps,
			"hold_shape": detectHoldShape(keyposes: timingOp.keyposes),
		]
	}

	/// Interleave: preserved keyposes get their value from existing state
	/// (by time match, tolerance 0.005); new keyposes pull from Pass 2's
	/// `values` in order. This makes preservation deterministic regardless
	/// of what Pass 2 does.
	private static func interleaveValues(
		keyposes: [TimingKeypose],
		newValues: [[Double]],
		existingKeyposes: [(time: Double, values: [Double])]
	) -> [[Double]] {
		var out: [[Double]] = []
		var nextNewIdx = 0
		for kp in keyposes {
			if kp.isPreserved {
				if let match = existingKeyposes.first(
					where: { abs($0.time - kp.time) < 0.005 })
				{
					out.append(match.values)
				} else if nextNewIdx < newValues.count {
					out.append(newValues[nextNewIdx])
					nextNewIdx += 1
				} else {
					out.append([])
				}
			} else {
				if nextNewIdx < newValues.count {
					out.append(newValues[nextNewIdx])
					nextNewIdx += 1
				} else {
					out.append([])
				}
			}
		}
		return out
	}

	private static func enforceHoldInvariant(
		keyposes: [TimingKeypose], values: inout [[Double]]
	) {
		for i in 0..<max(0, keyposes.count - 1) {
			if keyposes[i].intervalKind == "hold"
				&& i + 1 < values.count
				&& i < values.count
				&& values[i + 1] != values[i]
			{
				values[i + 1] = values[i]
			}
		}
	}

	/// Style fallback chain: Pass 3's pick → existing interval that overlaps
	/// this new one (deterministic preservation when Pass 3 was skipped) →
	/// hardcoded defaults.
	private static func resolveStyle(
		at i: Int, in keyposes: [TimingKeypose],
		styles: [StyleChoice],
		existingIntervals: [(start: Double, end: Double, curve: String, modulation: String)]
	) -> StyleChoice {
		if i < styles.count { return styles[i] }
		let intervalStart = keyposes[i].time
		let intervalEnd =
			i + 1 < keyposes.count
			? keyposes[i + 1].time : keyposes[i].time
		if let match = existingIntervals.first(where: {
			intervalStart < $0.end && intervalEnd > $0.start
		}) {
			return StyleChoice(curve: match.curve, modulation: match.modulation)
		}
		return StyleChoice(curve: "easeInOut", modulation: "none")
	}

	private static func encodeOutgoing(kind: String, style: StyleChoice) -> [String: Any] {
		if kind == "hold" {
			var outgoing: [String: Any] = [
				"curve": 0,
				"endpoints_linked": true,
				"intensity": 1.0,
				"frequency": 0.5,
			]
			let modCode = modulationCode[style.modulation.lowercased()] ?? 0
			if modCode != 0 {
				outgoing["modulation"] = modCode
				outgoing["modulation_intensity"] = 0.5
				outgoing["modulation_frequency"] = 0.5
				outgoing["modulation_linked"] = true
			}
			return outgoing
		}
		// transition: pick curve; modulation forced to none.
		return [
			"curve": curveCode[style.curve.lowercased()] ?? 3,
			"endpoints_linked": false,
			"intensity": 1.0,
			"frequency": 0.5,
		]
	}

	/// Match the keypose layout against the Basic three-phase model so the
	/// inspector knows which In/Out toggles to light up.
	///   0 = Auto (let the inspector infer)
	///   1 = None         (no holds)
	///   2 = InOnly       (transition then hold)
	///   3 = OutOnly      (hold then transition)
	///   4 = Both         (transition, hold, transition)
	private static func detectHoldShape(keyposes: [TimingKeypose]) -> Int {
		let n = keyposes.count
		guard n >= 2 else { return 0 }
		let isHold: (Int) -> Bool = { keyposes[$0].intervalKind == "hold" }

		switch n {
		case 2:
			return isHold(0) ? 0 : 1
		case 3:
			if isHold(0) && !isHold(1) { return 3 }
			if !isHold(0) && isHold(1) { return 2 }
			return 0
		case 4:
			if !isHold(0) && isHold(1) && !isHold(2) { return 4 }
			return 0
		default:
			return 0
		}
	}
}
