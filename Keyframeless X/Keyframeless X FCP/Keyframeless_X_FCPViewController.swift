/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Cocoa
import ProExtensionHost

@objc class Keyframeless_X_FCPViewController: NSViewController {

	override func awakeFromNib() {
		super.awakeFromNib()
	}

	override var nibName: NSNib.Name? {
		return NSNib.Name("Keyframeless_X_FCPViewController")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
	}

	@objc var hostInfoString: String {
		let host = ProExtensionHostSingleton() as! FCPXHost
		return String(format: "%@ %@", host.name, host.versionString)
	}

}
