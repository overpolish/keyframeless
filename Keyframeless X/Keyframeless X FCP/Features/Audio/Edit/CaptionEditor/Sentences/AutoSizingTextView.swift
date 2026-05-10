/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit

class AutoSizingTextView: NSTextView {
	override var intrinsicContentSize: NSSize {
		guard let container = textContainer, let layoutManager else {
			return super.intrinsicContentSize
		}
		layoutManager.ensureLayout(for: container)
		let rect = layoutManager.usedRect(for: container)
		return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height))
	}

	override func didChangeText() {
		super.didChangeText()
		invalidateIntrinsicContentSize()
	}

	override func layout() {
		super.layout()
		invalidateIntrinsicContentSize()
	}

	func configureZeroPadding() {
		textContainerInset = .zero
		textContainer?.lineFragmentPadding = 0
		textContainer?.widthTracksTextView = true
		isVerticallyResizable = true
		isHorizontallyResizable = false
		drawsBackground = false
	}
}
