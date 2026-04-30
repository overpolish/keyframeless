/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation
import ProExtensionHost

enum FCPHost {
	static var shared: FCPXHost {
		ProExtensionHostSingleton() as! FCPXHost
	}
}
