/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation
import ProExtensionHost

enum FCPHost {
	static var shared: FCPXHost {
		ProExtensionHostSingleton() as! FCPXHost
	}
}
