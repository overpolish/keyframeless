/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct ScrollShadowView<Content: View>: View {
	let shadowHeight: CGFloat
	let cornerRadius: CGFloat
	@ViewBuilder var content: () -> Content

	@State private var topOpacity: CGFloat = 0
	@State private var bottomOpacity: CGFloat = 0

	init(
		shadowHeight: CGFloat = 20, cornerRadius: CGFloat = 0,
		@ViewBuilder content: @escaping () -> Content
	) {
		self.shadowHeight = shadowHeight
		self.cornerRadius = cornerRadius
		self.content = content
	}

	var body: some View {
		ScrollView {
			ZStack {
				content()
				GeometryReader { inner in
					Color.clear
						.anchorPreference(key: ContentFrameKey.self, value: .bounds) { anchor in
							inner.frame(in: .named("scroll"))
						}
				}
			}
		}
		.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
		.coordinateSpace(name: "scroll")
		.overlayPreferenceValue(ContentFrameKey.self) { contentFrame in
			GeometryReader { viewport in
				let viewportH = viewport.size.height
				let contentH = contentFrame?.height ?? viewportH
				let scrollableDistance = contentH - viewportH
				let canScroll = scrollableDistance > 0
				let scrolledDown = -(contentFrame?.minY ?? 0)
				let scrollPercent = canScroll ? scrolledDown / scrollableDistance : 0

				Color.clear
					.overlay(alignment: .top) {
						LinearGradient(
							colors: [Color.black.opacity(0.15), .clear],
							startPoint: .top,
							endPoint: .bottom
						)
						.frame(height: shadowHeight)
						.opacity(min(max(scrollPercent, 0), 1))
					}
					.overlay(alignment: .bottom) {
						LinearGradient(
							colors: [.clear, Color.black.opacity(0.3)],
							startPoint: .top,
							endPoint: .bottom
						)
						.frame(height: shadowHeight)
						.opacity(canScroll ? min(max(1 - scrollPercent, 0), 1) : 0)
					}
			}
			.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
			.allowsHitTesting(false)
		}
	}
}

private struct ContentFrameKey: PreferenceKey {
	static var defaultValue: CGRect? { nil }
	static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
		value = nextValue() ?? value
	}
}
