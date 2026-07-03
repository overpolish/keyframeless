/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import SwiftUI

public struct PopoverGlassFix: ViewModifier {
	public init() {}

	public func body(content: Content) -> some View {
		content
			// A dark backing wash subdues macOS 26's Liquid Glass so the popover UI
			// keeps contrast over bright viewer backgrounds. Mirrors the kit's 0.2
			// black wash on the timeline inspector / layer-list popovers.
			.background(Color.black.opacity(0.2))
			.background(PopoverGlassFixProbe())
	}
}

extension View {
	public func popoverGlassFix() -> some View {
		modifier(PopoverGlassFix())
	}
}

private struct PopoverGlassFixProbe: NSViewRepresentable {
	func makeNSView(context: Context) -> ProbeView { ProbeView() }
	func updateNSView(_ nsView: ProbeView, context: Context) {}

	final class ProbeView: NSView {
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard window != nil else { return }
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
				guard let self else { return }
				Self.clearPopoverBackground(from: self)
			}
		}

		static func clearPopoverBackground(from start: NSView) {
			var current: NSView? = start
			var popoverFrame: NSView?
			while let c = current {
				if NSStringFromClass(type(of: c)).hasPrefix("NSPopoverFrame") {
					popoverFrame = c
					break
				}
				current = c.superview
			}
			guard let popoverFrame else { return }
			for sub in popoverFrame.subviews {
				guard NSStringFromClass(type(of: sub)).contains("GlassView") else { continue }
				for glassSub in sub.subviews {
					glassSub.wantsLayer = true
					let name = NSStringFromClass(type(of: glassSub))
					if name.contains("CoreHostingView") {
						glassSub.layer?.opacity = 0
					} else if name.contains("ContentHolderView") {
						glassSub.layer?.backgroundColor = NSColor.clear.cgColor
					}
				}
				break
			}
		}
	}
}
