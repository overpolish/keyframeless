/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct KKSeparatorRepresentable: NSViewRepresentable {
	var text: String? = nil
	var icon: NSImage? = nil

	func makeNSView(context: Context) -> KKSeparatorView {
		KKSeparatorView(text: text, icon: icon)
	}

	func updateNSView(_ nsView: KKSeparatorView, context: Context) {
		nsView.text = text
		nsView.icon = icon
	}
}
