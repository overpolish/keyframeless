/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import CoreMedia
import Foundation
import ProExtensionHost

class CaptionsModel: ObservableObject {

	@Published var timelineDuration: String = "—"
	@Published var projectFormat: FCPXMLParser.ProjectFormat?

	func updateFromTimeline() {
		guard let timeline = FCPHost.shared.timeline else {
			timelineDuration = "—"
			return
		}
		let seconds = CMTimeGetSeconds(timeline.sequenceTimeRange.duration)
		if seconds.isNaN || seconds < 0 {
			timelineDuration = "—"
		} else {
			timelineDuration = String(format: "%.2fs", seconds)
		}
	}

	func insertTitle() {
		let fcpxml = FCPXMLBuilder.titleStorylineXML(text: "hello from keyframeless x")
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("keyframeless_title.fcpxml")
		try? fcpxml.write(to: tmpURL, atomically: true, encoding: .utf8)
		NSWorkspace.shared.open(tmpURL)
	}

}
