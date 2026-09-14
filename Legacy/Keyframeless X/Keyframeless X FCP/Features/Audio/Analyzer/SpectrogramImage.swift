/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Accelerate
import CoreGraphics
import Foundation

/// Rasterised spectrogram pixels. `Sendable`, so the expensive part can happen
/// off the main thread and only the cheap `CGImage` wrap happens on it.
struct RGBBuffer: Sendable {
	let pixels: Data
	let width: Int
	let height: Int

	func cgImage() -> CGImage? {
		guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
		return CGImage(
			width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
			bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
			provider: provider, decode: nil, shouldInterpolate: false,
			intent: .defaultIntent)
	}
}

extension Spectrogram {
	/// Rasterises `frameRange` (default: the whole grid) into at most `maxWidth`
	/// columns of raw RGB: x = time, y = frequency, low frequencies at the bottom.
	///
	/// A bitmap is the right primitive for a spectrogram - one image beats drawing
	/// tens of thousands of individual cells. Frames bucket down to `maxWidth`,
	/// each column taking the *max* of its bucket so transients survive. At a
	/// 1/60s hop an hour-long timeline is ~216k frames, and a bitmap that wide
	/// exceeds image texture limits (it silently draws only the leading part and
	/// leaves the rest black) - besides which it just gets scaled down for display
	/// anyway.
	///
	/// `frameRange` exists so a zoomed-in view can raster just the frames on
	/// screen at screen resolution: the overview bitmap caps at 16384 columns,
	/// which is every frame of a 4.5-minute project but only a fraction of a long
	/// one, so past that zoom it has no detail left to give. A window costs screen
	/// width regardless of how long the project is.
	///
	/// Returns bytes rather than an image so this can run off the main thread -
	/// `Data` crosses actors, `CGImage` doesn't. Rasterising a long timeline is
	/// millions of samples and has no business blocking the UI.
	///
	/// `async` and `nonisolated`, so callers on the main actor hop off it AND the
	/// work stays inside the calling task - which is what makes cancellation
	/// reach the loop below. Handing this to a detached task instead would let a
	/// superseded raster run to completion, unstoppable, holding megabytes.
	nonisolated func rgbPixels(maxWidth: Int, frameRange: Range<Int>? = nil) async -> RGBBuffer? {
		let range = (frameRange ?? 0..<numFrames).clamped(to: 0..<max(numFrames, 1))
		let frameCount = range.count
		guard frameCount > 0 else { return nil }
		let w = max(1, min(frameCount, maxWidth))
		let h = max(1, numBands)
		guard w > 0, h > 0, !data.isEmpty else { return nil }
		var pixels = [UInt8](repeating: 0, count: w * h * 3)
		var peaks = [Float](repeating: 0, count: numBands)

		let cancelled = data.withUnsafeBufferPointer { src in
			pixels.withUnsafeMutableBufferPointer { dst in
				peaks.withUnsafeMutableBufferPointer { peak in
					Self.rampLUT.withUnsafeBufferPointer { lut in
						guard let srcBase = src.baseAddress, let peakBase = peak.baseAddress
						else { return false }
						let n = vDSP_Length(numBands)
						// Frames walk in memory order (bands innermost, sequential in
						// `data`). Band-by-band strode across the whole grid per band and
						// missed cache on nearly every read.
						for x in 0..<w {
							// Bail on a superseded zoom/selection rather than finishing a
							// picture that's already wrong. Checked per column-block: often
							// enough to stop promptly, rare enough not to cost anything.
							if x & 0xFF == 0, Task.isCancelled { return true }
							let lo = range.lowerBound + frameCount * x / w
							let hi = max(
								lo + 1,
								min(
									range.lowerBound + frameCount * (x + 1) / w,
									range.upperBound))
							// Column = elementwise max across the bucket's frames, so
							// transients survive being squeezed into one pixel.
							// `vDSP` is precompiled, so this runs at full speed even in a
							// debug build - where a hand-written loop does not.
							vDSP_vfill([0], peakBase, 1, n)
							for f in lo..<hi {
								vDSP_vmax(
									peakBase, 1, srcBase + f * numBands, 1, peakBase, 1, n)
							}
							for b in 0..<numBands {
								let y = numBands - 1 - b  // low frequencies at the bottom
								let idx = Int(max(0, min(255, peak[b] * 255))) * 3
								let offset = (y * w + x) * 3
								dst[offset] = lut[idx]
								dst[offset + 1] = lut[idx + 1]
								dst[offset + 2] = lut[idx + 2]
							}
						}
						return false
					}
				}
			}
		}
		if cancelled { return nil }
		return RGBBuffer(pixels: Data(pixels), width: w, height: h)
	}

	/// Magma-style ramp: near-black -> indigo -> magenta -> orange -> pale
	/// yellow. Reads like a studio spectrogram: quiet detail stays legible
	/// while loud content still pops.
	private static let ramp: [(Float, SIMD3<Float>)] = [
		(0.00, SIMD3(0.02, 0.02, 0.08)),
		(0.25, SIMD3(0.24, 0.06, 0.42)),
		(0.50, SIMD3(0.65, 0.13, 0.45)),
		(0.75, SIMD3(0.96, 0.44, 0.20)),
		(1.00, SIMD3(0.99, 0.95, 0.75)),
	]

	/// The colour ramp, baked to a 256-entry RGB table.
	///
	/// `rampColor` scans the gradient stops and interpolates in SIMD per call -
	/// fine for a few thousand pixels, ruinous for the millions a full-resolution
	/// raster needs, and it doesn't inline in a debug build. At 8 bits per
	/// channel the ramp has only 256 distinct outputs, so computing it per pixel
	/// was always redundant.
	static let rampLUT: [UInt8] = {
		var lut = [UInt8](repeating: 0, count: 256 * 3)
		for i in 0..<256 {
			let (r, g, b) = rampColor(Float(i) / 255)
			lut[i * 3] = r
			lut[i * 3 + 1] = g
			lut[i * 3 + 2] = b
		}
		return lut
	}()

	private static func rampColor(_ v: Float) -> (UInt8, UInt8, UInt8) {
		let x = min(max(v, 0), 1)
		var lo = ramp[0]
		var hi = ramp[ramp.count - 1]
		for i in 0..<(ramp.count - 1) where x >= ramp[i].0 && x <= ramp[i + 1].0 {
			lo = ramp[i]
			hi = ramp[i + 1]
			break
		}
		let t = (x - lo.0) / max(0.0001, hi.0 - lo.0)
		let c = lo.1 + (hi.1 - lo.1) * t
		func byte(_ f: Float) -> UInt8 { UInt8(max(0, min(255, f * 255))) }
		return (byte(c.x), byte(c.y), byte(c.z))
	}
}
