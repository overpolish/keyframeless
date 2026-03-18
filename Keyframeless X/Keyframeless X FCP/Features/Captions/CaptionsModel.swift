/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import Foundation

class CaptionsModel: ObservableObject {

	@Published var projectFormat: FCPXMLParser.ProjectFormat?

	func insertTitle() {
		let fcpxml = FCPXMLBuilder.titleStorylineXML(text: "hello from keyframeless x")
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("keyframeless_title.fcpxml")
		try? fcpxml.write(to: tmpURL, atomically: true, encoding: .utf8)
		NSWorkspace.shared.open(tmpURL)
	}

}
