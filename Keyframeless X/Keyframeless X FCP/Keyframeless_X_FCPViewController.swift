/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Cocoa
import KeyframelessKit
import ProExtensionHost
import SwiftUI

@objc class Keyframeless_X_FCPViewController: NSViewController {

	private let model = AudioModel()

	override func loadView() {
		view = NSView()
		KKHostInfo.shared().isWorkflowExtension = true
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		let hostingVC = NSHostingController(rootView: AppShell(audioModel: model))
		hostingVC.sizingOptions = []
		addChild(hostingVC)
		hostingVC.view.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(hostingVC.view)
		NSLayoutConstraint.activate([
			hostingVC.view.topAnchor.constraint(equalTo: view.topAnchor),
			hostingVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			hostingVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			hostingVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
		])

	}

	override func viewDidAppear() {
		super.viewDidAppear()
		view.window?.title = ""
	}

	@objc var hostInfoString: String {
		let host = FCPHost.shared
		return String(format: "%@ %@", host.name, host.versionString)
	}

}
