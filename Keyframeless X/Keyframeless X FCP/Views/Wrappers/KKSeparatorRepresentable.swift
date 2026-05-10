/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
