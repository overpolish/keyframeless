/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AVFoundation
import Foundation

/// Bounds how many audio extractions decode concurrently. Each extraction does
/// blocking `AVAssetReader.copyNextSampleBuffer` I/O; running one per clip (a
/// heavily-cut project can be dozens) blocks every thread in the Swift
/// cooperative pool at once, so no async work can make progress and the UI
/// freezes. Capping keeps most pool threads free and cuts reader contention on
/// the shared source file.
actor AudioExtractionLimiter {
	static let shared = AudioExtractionLimiter(limit: 4)

	private let limit: Int
	private var active = 0
	private var waiters: [CheckedContinuation<Void, Never>] = []

	init(limit: Int) { self.limit = limit }

	func acquire() async {
		if active < limit {
			active += 1
			return
		}
		// Resumed by release(), which hands off its slot without touching `active`.
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		if waiters.isEmpty {
			active -= 1
		} else {
			waiters.removeFirst().resume()
		}
	}
}

actor ProcessedAudioRenderer {
	static let shared = ProcessedAudioRenderer()

	/// One cached render. Kept together rather than spread across dictionaries
	/// keyed by the same string, so a file's size and its lease can't drift out
	/// of step with the file itself.
	private struct Entry {
		let url: URL
		let size: UInt64
		var leases: Int
		/// A monotonic tick, not a timestamp: this only has to order uses
		/// against each other, and a wall clock can jump backwards.
		var lastUsed: UInt64
	}

	private var entries: [String: Entry] = [:]
	private var inflight: [String: Task<URL, Error>] = [:]
	private var tick: UInt64 = 0

	/// Summed on demand rather than tracked: a running total is one more thing
	/// to keep in step with `entries`, and there are only ever a handful.
	private var totalBytes: UInt64 { entries.values.reduce(0) { $0 + $1.size } }

	private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "avi"]

	/// A rendered clip is uncompressed Float32 at the source rate, so 48kHz
	/// stereo costs ~1.4GB per hour, and every edit to a clip mints a fresh
	/// fingerprint and a fresh file. Each consumer caches its own derived result
	/// (waveform buckets, STFT frames) under that same fingerprint, so a kept
	/// WAV only ever saves a repeat decode - worth some disk, not unbounded
	/// disk. The cap is in bytes because one long clip outweighs dozens of
	/// short ones.
	private static let budgetBytes: UInt64 = 3 << 30

	/// Renders get their own directory so `TempJanitor` can clear a dead run's
	/// leftovers wholesale, rather than pattern-matching them out of the tmp
	/// root alongside everything else that lands there.
	static let directory = FileManager.default.temporaryDirectory
		.appendingPathComponent("KKProcessedAudio", isDirectory: true)

	/// Runs `body` with a rendered copy of `clip`'s processed audio.
	///
	/// The file is guaranteed to outlive the call and may be evicted any time
	/// after it, so read what you need inside and don't hold the URL.
	func withRenderedAudio<T: Sendable>(
		for clip: FCPXMLParser.AudioClip,
		_ body: @Sendable (URL) async throws -> T
	) async throws -> T {
		let key = Self.cacheKey(for: clip)
		let url = try await acquire(key: key, clip: clip)
		defer { release(key) }
		return try await body(url)
	}

	/// Returns a cached or freshly rendered file with its lease already held, so
	/// eviction can't pull it out from under the caller in the window between
	/// the lookup and the read.
	private func acquire(key: String, clip: FCPXMLParser.AudioClip) async throws -> URL {
		if let entry = entries[key], FileManager.default.fileExists(atPath: entry.url.path) {
			lease(key)
			return entry.url
		}
		// The file vanished under us (a manual tmp purge, say). Drop the entry
		// rather than let a dead path wedge the key for the rest of the session.
		entries[key] = nil

		let task: Task<URL, Error>
		if let existing = inflight[key] {
			task = existing
		} else {
			task = Task<URL, Error> {
				await AudioExtractionLimiter.shared.acquire()
				defer { Task { await AudioExtractionLimiter.shared.release() } }
				return try await Self.render(clip: clip)
			}
			inflight[key] = task
		}

		let url: URL
		do {
			url = try await task.value
		} catch {
			if inflight[key] == task { inflight[key] = nil }
			throw error
		}
		if inflight[key] == task { inflight[key] = nil }
		// Every waiter on a shared task resumes here, so only the first one to
		// arrive records the file - the rest would double-count it.
		if entries[key] == nil {
			entries[key] = Entry(url: url, size: Self.fileSize(url), leases: 0, lastUsed: 0)
		}
		lease(key)
		evictIfOverBudget()
		return url
	}

	/// Takes a lease and marks the entry most-recently-used.
	private func lease(_ key: String) {
		tick += 1
		entries[key]?.leases += 1
		entries[key]?.lastUsed = tick
	}

	private func release(_ key: String) {
		guard let leases = entries[key]?.leases, leases > 0 else { return }
		entries[key]?.leases = leases - 1
	}

	/// Oldest first, skipping anything a caller is currently reading.
	private func evictIfOverBudget() {
		var total = totalBytes
		guard total > Self.budgetBytes else { return }
		let candidates =
			entries
			.filter { $0.value.leases == 0 }
			.sorted { $0.value.lastUsed < $1.value.lastUsed }
		for (key, entry) in candidates {
			guard total > Self.budgetBytes else { break }
			try? FileManager.default.removeItem(at: entry.url)
			entries[key] = nil
			total -= entry.size
		}
	}

	private static func fileSize(_ url: URL) -> UInt64 {
		let values = try? url.resourceValues(forKeys: [.fileSizeKey])
		return UInt64(values?.fileSize ?? 0)
	}

	private static func cacheKey(for clip: FCPXMLParser.AudioClip) -> String {
		AudioClipFingerprint.of(clip)
	}

	private static func render(clip: FCPXMLParser.AudioClip) async throws -> URL {
		let resolved = try clip.resolvedURL()
		defer { resolved.stopAccess() }

		let isVideo = videoExtensions.contains(resolved.url.pathExtension.lowercased())
		let sourceURL: URL
		let extractedTemp: URL?
		let needsChannelExtraction = clip.channelWeights != nil
		let extractedTrimmedToClip: Bool
		if isVideo || needsChannelExtraction
			|| (try? AVAudioFile(
				forReading: resolved.url, commonFormat: .pcmFormatFloat32, interleaved: false))
				== nil
		{
			let extracted = try await AudioPreparer.extractAudioTrack(
				from: resolved.url, weights: clip.channelWeights,
				timeRange: (clip.sourceStart, clip.sourceDuration))
			sourceURL = extracted
			extractedTemp = extracted
			extractedTrimmedToClip = true
		} else {
			sourceURL = resolved.url
			extractedTemp = nil
			extractedTrimmedToClip = false
		}
		defer {
			if let t = extractedTemp { try? FileManager.default.removeItem(at: t) }
		}

		let audioFile = try AVAudioFile(
			forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
		let sampleRate = audioFile.fileFormat.sampleRate
		let startFrame: AVAudioFramePosition
		let endFrame: AVAudioFramePosition
		if extractedTrimmedToClip {
			startFrame = 0
			endFrame = audioFile.length
		} else {
			startFrame = AVAudioFramePosition(clip.sourceStart * sampleRate)
			endFrame = min(
				AVAudioFramePosition((clip.sourceStart + clip.sourceDuration) * sampleRate),
				audioFile.length)
		}
		let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
		audioFile.framePosition = max(0, startFrame)

		guard
			let buffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)
		else {
			throw NSError(domain: "ProcessedAudioRenderer", code: 1)
		}
		try audioFile.read(into: buffer, frameCount: frameCount)

		let mapping = AudioPreparer.ClipMapping(
			clipIndex: 0,
			offsetInSegment: 0,
			clipSourceStart: clip.sourceStart,
			clipSourceDuration: clip.sourceDuration,
			volumeCurve: clip.volumeCurve,
			fadeIn: clip.fadeIn,
			fadeOut: clip.fadeOut,
			outer: clip.outer
		)
		AudioPreparer.applyVolumeCurves(
			buffer: buffer,
			segmentStart: clip.sourceStart,
			sampleRate: sampleRate,
			mappings: [mapping]
		)

		var processed = buffer
		if let filters = clip.auFilters, !filters.isEmpty {
			processed = try await AudioUnitRenderer.process(
				buffer: buffer, filters: filters, baseSourceTime: clip.sourceStart)
		}

		try FileManager.default.createDirectory(
			at: Self.directory, withIntermediateDirectories: true)
		let outURL = Self.directory.appendingPathComponent(
			"kk_processed_\(UUID().uuidString).wav")
		let outFile = try AVAudioFile(forWriting: outURL, settings: processed.format.settings)
		try outFile.write(from: processed)
		return outURL
	}
}
