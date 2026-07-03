/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessAILocal

// The shared local-inference helper. Installed once by the "Keyframeless AI"
// package and launched on demand by launchd (an app-group Mach service the
// sandboxed plugins look up); run() binds the app-group unix socket, checks in
// for the wake service, loads the model on first request, and idle-exits.
LocalAIHelperServer.run()
