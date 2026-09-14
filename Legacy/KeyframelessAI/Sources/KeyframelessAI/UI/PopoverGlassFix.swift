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
			// An OPAQUE inspector-matched fill so the popover UI reads on a flat
			// surface instead of see-through liquid glass. Sits on top of the glass
			// (it's our hosted content), so it guarantees legibility regardless of
			// the private popover-frame hierarchy. Mirrors the kit's opaque
			// KKApplyPopoverBackground on the ObjC popovers.
			.background(Color.aiPopoverBackground.opacity(0.5))
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
			let fill = NSColor(
				red: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x16 / 255.0, alpha: 0.5
			).cgColor
			for sub in popoverFrame.subviews {
				guard NSStringFromClass(type(of: sub)).contains("GlassView") else { continue }
				for glassSub in sub.subviews {
					glassSub.wantsLayer = true
					let name = NSStringFromClass(type(of: glassSub))
					if name.contains("CoreHostingView") {
						glassSub.layer?.opacity = 0
					} else if name.contains("ContentHolderView") {
						glassSub.layer?.backgroundColor = fill
					}
				}
				break
			}
		}
	}
}
