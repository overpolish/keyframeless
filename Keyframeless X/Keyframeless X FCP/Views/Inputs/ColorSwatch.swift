/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct ColorSwatch: View {
	@Binding var colorR: Double
	@Binding var colorG: Double
	@Binding var colorB: Double
	@Binding var colorA: Double

	private var nsColor: NSColor {
		NSColor(red: colorR, green: colorG, blue: colorB, alpha: colorA)
	}

	var body: some View {
		ZStack {
			WindowAccessor { window in
				ColorPanelController.shared.hostWindow = window
			}
			.frame(width: 0, height: 0)
			Button {
				ColorPanelController.shared.show(color: nsColor) { color in
					guard let c = color.usingColorSpace(.sRGB) else { return }
					colorR = Double(c.redComponent)
					colorG = Double(c.greenComponent)
					colorB = Double(c.blueComponent)
					colorA = Double(c.alphaComponent)
				}
			} label: {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.fill(Color(nsColor: nsColor))
					.frame(width: 20, height: 20)
					.overlay(
						RoundedRectangle(cornerRadius: KKRadiusMD)
							.strokeBorder(.secondary.opacity(0.3), lineWidth: KKBorderWidthXS)
					)
			}
			.buttonStyle(.plain)
		}
	}
}

private struct WindowAccessor: NSViewRepresentable {
	var onWindow: (NSWindow) -> Void

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			if let window = view.window { onWindow(window) }
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		if let window = nsView.window { onWindow(window) }
	}
}

private final class ColorPanelController: NSObject {
	static let shared = ColorPanelController()
	weak var hostWindow: NSWindow?
	private var onChange: ((NSColor) -> Void)?

	func show(color: NSColor, onChange: @escaping (NSColor) -> Void) {
		self.onChange = onChange
		let panel = NSColorPanel.shared
		panel.showsAlpha = true
		panel.color = color
		panel.setTarget(self)
		panel.setAction(#selector(colorDidChange(_:)))
		if let host = hostWindow, panel.parent !== host {
			panel.parent?.removeChildWindow(panel)
			host.addChildWindow(panel, ordered: .above)
		}
		panel.orderFront(nil)
	}

	@objc private func colorDidChange(_ sender: NSColorPanel) {
		onChange?(sender.color)
	}
}
