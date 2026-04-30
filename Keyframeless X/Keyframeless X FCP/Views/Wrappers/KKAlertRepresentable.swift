/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import KeyframelessKit
import SwiftUI

struct KKAlertRepresentable: NSViewRepresentable {
	let text: String
	var icon: NSImage? = nil
	var fontSize: CGFloat? = nil

	func makeNSView(context: Context) -> KKAlertView {
		let view = KKAlertView(text: text)
		if let fontSize { applyFontSize(fontSize, to: view) }
		return view
	}

	func updateNSView(_ nsView: KKAlertView, context: Context) {
		nsView.text = text
		nsView.icon = icon
		if let fontSize { applyFontSize(fontSize, to: nsView) }
	}

	private func applyFontSize(_ size: CGFloat, to view: KKAlertView) {
		for case let label as NSTextField in view.subviews.flatMap({ $0.subviews }) {
			label.font = NSFont.systemFont(ofSize: size)
		}
	}
}
