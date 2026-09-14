/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

/// On macOS 26, popovers use liquid glass but the system places a
/// `_NSCoreHostingView<RootView>` inside `NSGlassView` that draws an opaque
/// background over the glass, creating a visible inner border. This view walks
/// the NSView hierarchy and hides that system background so the liquid glass
/// effect is fully visible.
///
/// Usage: `.background(PopoverBackgroundClearer())` on the popover content.
struct PopoverBackgroundClearer: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		if #available(macOS 26, *) {
			DispatchQueue.main.async {
				guard let popoverFrame = self.findAncestor(from: view, matching: "NSPopoverFrame")
				else { return }
				self.clearSystemBackground(in: popoverFrame)
			}
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {}

	private func findAncestor(from view: NSView, matching name: String) -> NSView? {
		var current: NSView? = view
		while let v = current {
			if String(describing: type(of: v)).hasPrefix(name) {
				return v
			}
			current = v.superview
		}
		return nil
	}

	private func clearSystemBackground(in popoverFrame: NSView) {
		for sub in popoverFrame.subviews {
			let typeName = String(describing: type(of: sub))
			guard typeName.hasPrefix("NSGlassView") else { continue }
			for glassSub in sub.subviews {
				let glassSubType = String(describing: type(of: glassSub))
				if glassSubType.hasPrefix("_NSCoreHostingView") {
					glassSub.wantsLayer = true
					glassSub.layer?.opacity = 0
				} else if glassSubType == "ContentHolderView" {
					glassSub.wantsLayer = true
					glassSub.layer?.backgroundColor = .clear
				}
			}
		}
	}
}
