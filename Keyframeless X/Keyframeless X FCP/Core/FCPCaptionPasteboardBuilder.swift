/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import Foundation

/// Builds a native FCP proFFPasteboard blob of caption clips for paste/drag onto the
/// current timeline (true playhead paste, unlike the FCPXML import which lands a new project).
/// Clones a captured single-caption template (BasicCaptionTemplate.plist), patching text,
/// per-character rubyText length, timing and the caption-format role/class per segment.
enum FCPCaptionPasteboardBuilder {

	struct Entry {
		let text: String
		let startTime: Double
		let duration: Double
	}

	static func build(
		captions: [Entry],
		format: CaptionFormat,
		frameDuration: String,
		mediaStartTime: Double = 3600.0
	) -> Data? {
		guard !captions.isEmpty else { return nil }
		let fr = FCPNativePasteboardBuilder.parseFrameDuration(frameDuration)

		guard
			let url = Bundle(for: FCPDragSourceView.self)
				.url(forResource: "BasicCaptionTemplate", withExtension: "plist"),
			let data = try? Data(contentsOf: url),
			var plist = try? PropertyListSerialization.propertyList(
				from: data, options: .mutableContainersAndLeaves, format: nil) as? [String: Any],
			let objData = plist["ffpasteboardobject"] as? Data,
			var archive = try? PropertyListSerialization.propertyList(
				from: objData, options: .mutableContainersAndLeaves, format: nil) as? [String: Any],
			var objects = archive["$objects"] as? [Any]
		else { return nil }

		func uid(_ v: Any) -> Int? {
			if v is [String: Any] || v is [Any] { return nil }
			return FCPNativePasteboardBuilder.uidValue(v)
		}
		func u(_ d: [String: Any], _ k: String) -> Int? {
			if let v = d[k] { return uid(v) }
			return nil
		}
		func items(_ i: Int) -> [Int] {
			(objects[i] as? [String: Any]).flatMap {
				($0["NS.objects"] as? [Any])?.compactMap { uid($0) }
			} ?? []
		}
		func frameCount(_ s: Double) -> Int {
			FCPNativePasteboardBuilder.frames(seconds: s, frameRate: fr)
		}
		func ticks(_ s: Double) -> Int { frameCount(s) * fr.numerator }

		// The bundled template carries one genuine caption per format (iTT/SRT/CEA-608), each with
		// its real ivar layout (SRT/CEA-608 lack the rubyText/regionString that iTT has). Pick the
		// caption root whose roleUID matches the requested format and clone THAT - never transmute
		// an iTT caption into another class, which produces a malformed object that crashes FCP.
		var gapIdx = -1
		var containerIdx = -1
		var capRootForRole = [String: Int]()
		for (i, o) in objects.enumerated() {
			guard let d = o as? [String: Any] else { continue }
			if d["captionTextBlocks"] != nil, let ru = u(d, "roleUID"),
				let role = objects[ru] as? String, capRootForRole[role] == nil
			{
				capRootForRole[role] = i
			}
			if d["anchoredItems"] != nil && d["displayName"] != nil { gapIdx = i }
			if d["containedItems"] != nil { containerIdx = i }
		}
		guard let capRoot = capRootForRole[format.pasteboardRoleUID],
			gapIdx >= 0, containerIdx >= 0
		else { return nil }

		func reachable(_ roots: [Int]) -> Set<Int> {
			var seen = Set<Int>()
			var stack = roots
			while let i = stack.popLast() {
				if i < 0 || seen.contains(i) { continue }
				seen.insert(i)
				func walk(_ v: Any) {
					if let dd = v as? [String: Any] {
						for (_, vv) in dd { walk(vv) }
					} else if let a = v as? [Any] {
						a.forEach(walk)
					} else if let x = uid(v) {
						stack.append(x)
					}
				}
				walk(objects[i])
			}
			return seen
		}
		var attrRoots = [Int]()
		var timeRoots = [Int]()
		var regionRoots = [Int]()
		for o in objects {
			guard let d = o as? [String: Any] else { continue }
			if d["attributedString"] != nil {
				if let t = u(d, "timeRange") { timeRoots.append(t) }
				if let r = u(d, "regionString") { regionRoots.append(r) }
			}
			if let a = u(d, "NSAttributes") { attrRoots.append(a) }
		}
		var classDefs = Set<Int>()
		for (i, o) in objects.enumerated() {
			if let d = o as? [String: Any], d["$classname"] != nil { classDefs.insert(i) }
		}
		var shared = reachable(attrRoots + timeRoots).union(classDefs)
		shared.formUnion(regionRoots)
		if let cap = objects[capRoot] as? [String: Any], let ru = u(cap, "roleUID") {
			shared.insert(ru)
		}
		let orderedClone = Array(reachable([capRoot]).subtracting(shared)).sorted()

		func patchPC(_ pc: Int, text: String, cc: Int) {
			guard let pcd = objects[pc] as? [String: Any] else { return }
			if let asU = u(pcd, "attributedString"), let asd = objects[asU] as? [String: Any],
				let nsU = u(asd, "NSString")
			{
				if objects[nsU] is String {
					objects[nsU] = text
				} else if var sd = objects[nsU] as? [String: Any] {
					sd["NS.string"] = text
					objects[nsU] = sd
				}
			}
			if let rtU = u(pcd, "rubyText"), var rt = objects[rtU] as? [String: Any],
				let objs = rt["NS.objects"] as? [Any], let first = objs.first
			{
				rt["NS.objects"] = Array(repeating: first, count: cc)
				objects[rtU] = rt
			}
			// CEA-608 is a 32-column character grid; cellX is the start column and is tied to the
			// template text's length. FCP right-aligns a single row ending at column 30, so recompute
			// cellX for the new text or it overflows the grid (red caption + garbled render).
			if pcd["cellX"] != nil {
				var d = pcd
				d["cellX"] = max(0, 30 - cc) as NSNumber
				objects[pc] = d
			}
		}
		// CEA-608 multi-row caption: one captionTextBlock holds N PCs (one per grid row) in
		// both AVCaptionArray and FFEncodedAVCaptionArray. Clone the template PC subtree
		// (pc + attributedString + NSString-wrapper) per extra row and patch each with row
		// text + cellY (15-N+1+rowIdx, bottom-anchored) + cellX (30-rowChars). iTT/SRT render
		// the attributed string's embedded \n directly so they fall through to single-PC patch.
		func clonePCSubtree(_ pc: Int) -> Int {
			let pcd = objects[pc] as? [String: Any] ?? [:]
			let asU = u(pcd, "attributedString")
			let asd = asU.flatMap { objects[$0] as? [String: Any] }
			let nsU = asd.flatMap { u($0, "NSString") }
			// FCP keys on the timeRange UID for per-row identity even when the CMTime values are
			// identical; sharing the original timeRange across cloned rows makes FCP conflate the
			// rows (duplicate row text on the multi-row caption, polluted neighbours). Clone the
			// timeRange dict + its two leaf CMTime dicts per row.
			let trU = u(pcd, "timeRange")
			let trd = trU.flatMap { objects[$0] as? [String: Any] }
			let trVals = ((trd?["NS.objects"]) as? [Any])?.compactMap { uid($0) } ?? []
			let toClone = ([pc, asU, nsU, trU].compactMap { $0 }) + trVals
			let base = objects.count
			var remap = [Int: Int]()
			for (off, idx) in toClone.enumerated() { remap[idx] = base + off }
			for idx in toClone {
				objects.append(FCPNativePasteboardBuilder.deepCopy(objects[idx], remap: remap))
			}
			return remap[pc]!
		}
		func fanRowsInto(arrIdx: Int, rows: [String]) {
			guard let arrObj = objects[arrIdx] as? [String: Any] else { return }
			let pcIndices = items(arrIdx)
			guard let templatePC = pcIndices.first else { return }
			var newPCs: [Int] = [templatePC]
			for _ in 1..<rows.count { newPCs.append(clonePCSubtree(templatePC)) }
			let rowCount = rows.count
			for (i, pc) in newPCs.enumerated() {
				let rowText = rows[i]
				let rowCC = (rowText as NSString).length
				patchPC(pc, text: rowText, cc: rowCC)
				if rowCount > 1, var d = objects[pc] as? [String: Any], d["cellY"] != nil {
					// Bottom-anchor: rowCount=2 → cellY 14,15; rowCount=3 → 13,14,15.
					d["cellY"] = (15 - (rowCount - 1) + i) as NSNumber
					objects[pc] = d
				}
			}
			var arr2 = arrObj
			arr2["NS.objects"] = newPCs.map { FCPNativePasteboardBuilder.makeUID($0) }
			objects[arrIdx] = arr2
		}
		func patchCaption(_ cr: Int, text: String, anchorSec: Double, durSec: Double) {
			let cc = (text as NSString).length
			let anchorPair = "{(0/1),(\(ticks(anchorSec))/\(fr.denominator))}"
			let clippedRange = "{(0/1),(\(ticks(durSec))/\(fr.denominator))}"
			guard let cap = objects[cr] as? [String: Any] else { return }
			// displayName is the inspector/timeline label - collapse \n so it reads as one line.
			let displayText = text.replacingOccurrences(of: "\n", with: " ")
			if let i = u(cap, "displayName") { objects[i] = displayText }
			if let i = u(cap, "anchorPair") { objects[i] = anchorPair }
			if let i = u(cap, "clippedRange") { objects[i] = clippedRange }
			if let i = u(cap, "persistentID") { objects[i] = UUID().uuidString.uppercased() }
			guard let tbArr = u(cap, "captionTextBlocks") else { return }
			let cea608Rows: [String]? =
				(format == .cea608 && text.contains("\n"))
				? text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
				: nil
			for tb in items(tbArr) {
				guard let tbd = objects[tb] as? [String: Any] else { continue }
				if let i = u(tbd, "persistentID") { objects[i] = UUID().uuidString.uppercased() }
				guard let avd = u(tbd, "avCaptionsDictionary"),
					let ad = objects[avd] as? [String: Any]
				else { continue }
				let keys = (ad["NS.keys"] as? [Any])?.compactMap { uid($0) } ?? []
				let vals = (ad["NS.objects"] as? [Any])?.compactMap { uid($0) } ?? []
				for (k, v) in zip(keys, vals) {
					let name = objects[k] as? String
					if name == "AVCaptionArray" || name == "FFEncodedAVCaptionArray" {
						if let rows = cea608Rows {
							fanRowsInto(arrIdx: v, rows: rows)
						} else {
							// Single-line path. Cap 0 reuses the template's actual capRoot, so its
							// fan-out mutates the template's AVCaptionArray.NS.objects in-place to
							// [origPC, cloneRow1]. Later captions' deepCopy walks the template array
							// and only remaps UIDs in orderedClone - the newly-appended cloneRow1
							// index leaks through unchanged. If THIS caption is single-line we must
							// drop those stale entries (else we'd patch both PCs with the same single-
							// line text and render a duplicated 2-row caption with a stale shared PC).
							let pcIndices = items(v)
							guard let keepPC = pcIndices.first else { continue }
							patchPC(keepPC, text: text, cc: cc)
							if pcIndices.count > 1, var arrObj = objects[v] as? [String: Any] {
								arrObj["NS.objects"] = [FCPNativePasteboardBuilder.makeUID(keepPC)]
								objects[v] = arrObj
							}
							// Reset cellY to bottom row for single-line (cap 0's fan-out left cellY=14).
							if var d = objects[keepPC] as? [String: Any], d["cellY"] != nil {
								d["cellY"] = 15 as NSNumber
								objects[keepPC] = d
							}
						}
					}
				}
			}
		}

		let sorted = captions.sorted { $0.startTime < $1.startTime }
		var capUIDs: [Any] = []
		var maxEndFrames = 0
		for (i, capn) in sorted.enumerated() {
			// Preserve the FULL offset from the first caption's RAW input position. CEA-608
			// pre-validation pushes cap[0] later (project-start lead-in); if we subtracted
			// firstStart here, that lead-in would be flattened to zero and FCP's own AVF
			// validation re-emits the cascading "too close to previous" errors. Anchoring at
			// (mediaStartTime + capn.startTime) keeps cap[0]'s lead-in window intact so the
			// captions land at playhead + capn.startTime, not playhead + 0.
			let anchorSec = mediaStartTime + capn.startTime
			let anchorFrame = frameCount(anchorSec)
			let ownEndFrame = frameCount(anchorSec + capn.duration)
			let endFrame: Int
			if i + 1 < sorted.count {
				let nextAnchorFrame = frameCount(mediaStartTime + sorted[i + 1].startTime)
				endFrame = min(ownEndFrame, nextAnchorFrame)
			} else {
				endFrame = ownEndFrame
			}
			let durFrames = max(1, endFrame - anchorFrame)
			let durSec = Double(durFrames) * Double(fr.numerator) / Double(fr.denominator)
			if i == 0 {
				patchCaption(capRoot, text: capn.text, anchorSec: anchorSec, durSec: durSec)
				capUIDs.append(FCPNativePasteboardBuilder.makeUID(capRoot))
			} else {
				var remap = [Int: Int]()
				let base = objects.count
				for (off, idx) in orderedClone.enumerated() { remap[idx] = base + off }
				for idx in orderedClone {
					objects.append(FCPNativePasteboardBuilder.deepCopy(objects[idx], remap: remap))
				}
				patchCaption(remap[capRoot]!, text: capn.text, anchorSec: anchorSec, durSec: durSec)
				capUIDs.append(FCPNativePasteboardBuilder.makeUID(remap[capRoot]!))
			}
			let mediaStartFrame = frameCount(mediaStartTime)
			maxEndFrames = max(maxEndFrames, anchorFrame + durFrames - mediaStartFrame)
		}

		if let gap = objects[gapIdx] as? [String: Any], let ai = u(gap, "anchoredItems"),
			var aiArr = objects[ai] as? [String: Any]
		{
			aiArr["NS.objects"] = capUIDs
			objects[ai] = aiArr
		}
		let totalTicks = maxEndFrames * fr.numerator
		if let gap = objects[gapIdx] as? [String: Any], let cr = u(gap, "clippedRange") {
			objects[cr] =
				"{(\(ticks(mediaStartTime))/\(fr.denominator)),(\(totalTicks)/\(fr.denominator))}"
		}
		if let cont = objects[containerIdx] as? [String: Any], let cr = u(cont, "clippedRange") {
			objects[cr] = "{(0/1),(\(totalTicks)/\(fr.denominator))}"
		}

		archive["$objects"] = objects
		guard
			let newObj = try? PropertyListSerialization.data(
				fromPropertyList: archive, format: .binary, options: 0)
		else { return nil }
		plist["ffpasteboardobject"] = newObj
		return try? PropertyListSerialization.data(
			fromPropertyList: plist, format: .binary, options: 0)
	}
}
