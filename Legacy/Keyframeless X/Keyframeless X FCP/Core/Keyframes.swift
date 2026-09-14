/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Generic linear interpolation across a sorted-by-time keyframe sequence.
/// Holds the first value before the start and the last value after the end.
enum Keyframes {
	static func interpolate<P>(
		_ points: [P], at t: Double,
		time: (P) -> Double, value: (P) -> Double
	) -> Double {
		guard let first = points.first, let last = points.last else { return 0 }
		if t <= time(first) { return value(first) }
		if t >= time(last) { return value(last) }
		for j in 1..<points.count {
			let a = points[j - 1]
			let b = points[j]
			if t <= time(b) {
				let span = time(b) - time(a)
				if span <= 0 { return value(b) }
				let f = (t - time(a)) / span
				return value(a) + (value(b) - value(a)) * f
			}
		}
		return value(last)
	}

	static func interpolateDB(
		_ points: [FCPXMLParser.VolumePoint], at t: Double
	) -> Double {
		interpolate(points, at: t, time: { $0.time }, value: { $0.dB })
	}

	static func interpolateParam(
		_ points: [FCPXMLParser.AudioFilter.ParamOverride.Keyframe], at t: Double
	) -> Float {
		Float(interpolate(points, at: t, time: { $0.time }, value: { Double($0.value) }))
	}
}
