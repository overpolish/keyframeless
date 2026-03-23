/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import SwiftUI

struct AnimatedGifView: NSViewRepresentable {
	let url: URL
	@Binding var progress: CGFloat

	func makeNSView(context: Context) -> NSImageView {
		let imageView = NSImageView()
		imageView.imageScaling = .scaleProportionallyUpOrDown
		imageView.animates = false
		imageView.canDrawSubviewsIntoLayer = true
		imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
		imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		imageView.unregisterDraggedTypes()

		if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
			let count = CGImageSourceGetCount(source)
			var delays: [Double] = []
			for i in 0..<count {
				let props =
					CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
				let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
				let delay =
					(gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
					?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double)
					?? 0.1
				delays.append(delay)
			}
			context.coordinator.start(
				source: source, delays: delays, imageView: imageView, progress: $progress)
		}

		return imageView
	}

	func updateNSView(_ nsView: NSImageView, context: Context) {}

	static func dismantleNSView(_ nsView: NSImageView, coordinator: Coordinator) {
		coordinator.stop()
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	class Coordinator {
		private var timer: Timer?
		private var source: CGImageSource?
		private var delays: [Double] = []
		private var currentFrame = 0
		private var progress: Binding<CGFloat>?
		private weak var imageView: NSImageView?

		func start(
			source: CGImageSource, delays: [Double], imageView: NSImageView,
			progress: Binding<CGFloat>
		) {
			self.source = source
			self.delays = delays
			self.imageView = imageView
			self.progress = progress
			currentFrame = 0
			showFrame(0)
			scheduleNext()
		}

		func stop() {
			timer?.invalidate()
			timer = nil
		}

		private func showFrame(_ index: Int) {
			guard let source,
				let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil)
			else { return }
			let image = NSImage(
				cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
			imageView?.image = image
			let count = CGImageSourceGetCount(source)
			DispatchQueue.main.async {
				self.progress?.wrappedValue = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
			}
		}

		private func scheduleNext() {
			guard !delays.isEmpty else { return }
			let delay = delays[currentFrame]
			timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
				guard let self, let source = self.source else { return }
				let count = CGImageSourceGetCount(source)
				self.currentFrame = (self.currentFrame + 1) % count
				self.showFrame(self.currentFrame)
				self.scheduleNext()
			}
		}
	}
}
