/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Cocoa
import ProExtensionHost
import SwiftUI

@objc class Keyframeless_X_FCPViewController: NSViewController {

	private let model = FCPModel()

	override func loadView() {
		view = NSView()
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		let hostingVC = NSHostingController(rootView: ContentView(model: model))
		addChild(hostingVC)
		hostingVC.view.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(hostingVC.view)
		NSLayoutConstraint.activate([
			hostingVC.view.topAnchor.constraint(equalTo: view.topAnchor),
			hostingVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			hostingVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			hostingVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
		])

		let host = ProExtensionHostSingleton() as! FCPXHost
		host.timeline?.add(self)
		model.updateFromTimeline()
	}

	override func viewDidAppear() {
		super.viewDidAppear()
		view.window?.title = ""
	}

	override func viewWillDisappear() {
		super.viewWillDisappear()
		let host = ProExtensionHostSingleton() as! FCPXHost
		host.timeline?.remove(self)
	}

	@objc var hostInfoString: String {
		let host = ProExtensionHostSingleton() as! FCPXHost
		return String(format: "%@ %@", host.name, host.versionString)
	}

}

extension Keyframeless_X_FCPViewController: FCPXTimelineObserver {
	func sequenceTimeRangeChanged() {
		DispatchQueue.main.async { self.model.updateFromTimeline() }
	}

	func activeSequenceChanged() {
		DispatchQueue.main.async { self.model.updateFromTimeline() }
	}
}
