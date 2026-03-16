/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct KKAlertRepresentable: NSViewRepresentable {
	let text: String
	var icon: NSImage? = nil

	func makeNSView(context: Context) -> KKAlertView {
		KKAlertView(text: text)
	}

	func updateNSView(_ nsView: KKAlertView, context: Context) {
		nsView.text = text
		nsView.icon = icon
	}
}
