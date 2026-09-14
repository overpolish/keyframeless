/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// One-shot cleanup of temp files a previous run left behind.
///
/// Everything the extension writes to tmp is regenerable, but nothing runs at
/// process exit to remove it: a crash, a cancelled model download, or FCP just
/// quitting strands whatever was in flight. The system only sweeps a sandboxed
/// container's tmp when the container is idle, which it rarely is, so the
/// residue survives every launch and grows without limit - it reached 19GB
/// before this existed.
///
/// Cleanup is by age, not by bookkeeping: a file that predates this process
/// cannot belong to it, so nothing live can be caught. That holds no matter how
/// the previous run died, which is the point - the failure mode being cleaned
/// up after is precisely the one where our own bookkeeping didn't run.
enum TempJanitor {

	/// Prefixes in the container tmp that are ours to remove.
	///
	/// `CFNetworkDownload_` is CFNetwork's own partial-download staging. We never
	/// create it - it appears when a transcription model download is cancelled or
	/// killed mid-flight - but it lands in our container, where nobody else will
	/// ever collect it. One abandoned model download left 5GB behind.
	private static let prefixes = [
		"kk_processed_",
		"kk_extracted_",
		"kk_segment_",
		"CFNetworkDownload_",
	]

	@MainActor private static var didRun = false

	/// Call once, at launch, before anything starts writing to tmp.
	@MainActor static func sweepOnce() {
		guard !didRun else { return }
		didRun = true
		// Captured here rather than inside the sweep: everything already on disk
		// predates every render and download this process will start, so by the
		// time the background work runs, age alone still separates dead residue
		// from live files.
		let cutoff = Date()
		// Sandboxed, so this is the extension's own container tmp, not a shared
		// system one - the prefix match never sees another app's files.
		let tmp = FileManager.default.temporaryDirectory
		// Directories taken from their owner rather than spelled out again here,
		// so a rename there can't quietly orphan them.
		let directories = [ProcessedAudioRenderer.directory]
		// A plain global queue, not a Task: this is blocking unlink I/O over
		// (observed) 1200+ files, and the Swift cooperative pool has one thread
		// per core to lose.
		DispatchQueue.global(qos: .utility).async {
			sweep(tmp: tmp, directories: directories, olderThan: cutoff)
		}
	}

	/// Takes its directories as arguments rather than reading them, so the sweep
	/// can be exercised against a scratch tree: `FileManager.temporaryDirectory`
	/// ignores `TMPDIR` on macOS, so there is no other way to test it.
	static func sweep(tmp: URL, directories: [URL], olderThan cutoff: Date) {
		let fm = FileManager.default
		var removed = 0
		var bytes: UInt64 = 0

		for dir in directories {
			for url in contents(of: dir) where isStale(url, cutoff: cutoff) {
				bytes += size(of: url)
				if (try? fm.removeItem(at: url)) != nil { removed += 1 }
			}
		}

		for url in contents(of: tmp) {
			let name = url.lastPathComponent
			guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
			guard isStale(url, cutoff: cutoff) else { continue }
			bytes += size(of: url)
			if (try? fm.removeItem(at: url)) != nil { removed += 1 }
		}

		if removed > 0 {
			let mb = Double(bytes) / 1_048_576
			print("[TempJanitor] removed \(removed) stale temp files (\(Int(mb)) MB)")
		}
	}

	private static func contents(of dir: URL) -> [URL] {
		(try? FileManager.default.contentsOfDirectory(
			at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
			options: [.skipsHiddenFiles])) ?? []
	}

	private static func isStale(_ url: URL, cutoff: Date) -> Bool {
		guard
			let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
				.contentModificationDate
		else { return false }
		return mtime < cutoff
	}

	private static func size(of url: URL) -> UInt64 {
		UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
	}
}
