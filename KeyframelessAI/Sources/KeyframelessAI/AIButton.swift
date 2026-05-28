/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

public struct AIButton: View {
	@State private var showPopover = false

	public init() {}

	public var body: some View {
		Button {
			showPopover.toggle()
		} label: {
			AnimatedSparkleIcon()
				.frame(width: 18, height: 18)
				.contentShape(Rectangle())
		}
		.buttonStyle(.borderless)
		.help("AI settings")
		.popover(isPresented: $showPopover, arrowEdge: .top) {
			AIKeySettingsView()
		}
	}
}

private struct AnimatedSparkleIcon: View {
	var body: some View {
		TimelineView(.animation) { context in
			let t = context.date.timeIntervalSinceReferenceDate
			let angle = Angle.degrees((t * 60).truncatingRemainder(dividingBy: 360))
			let shimmer = 0.5 + 0.5 * sin(t * 2.2)

			Image(systemName: "sparkles")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(.white)
				.overlay {
					AngularGradient(
						colors: [
							Color(red: 1.00, green: 0.42, blue: 0.71),
							Color(red: 0.55, green: 0.36, blue: 1.00),
							Color(red: 0.20, green: 0.78, blue: 1.00),
							Color(red: 0.30, green: 1.00, blue: 0.78),
							Color(red: 1.00, green: 0.84, blue: 0.30),
							Color(red: 1.00, green: 0.42, blue: 0.71),
						],
						center: .center,
						angle: angle
					)
					.mask(
						Image(systemName: "sparkles")
							.font(.system(size: 13, weight: .semibold))
					)
				}
				.shadow(
					color: Color(red: 0.55, green: 0.36, blue: 1.00).opacity(0.35 + 0.25 * shimmer),
					radius: 3 + 2 * shimmer
				)
		}
	}
}
