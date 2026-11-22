// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// The auto-dj command line. SwiftPM builds this as the `auto-dj` product; the Xcode project
// builds the same file as the `auto-dj` tool target that AutoDJ.app embeds.

import AutoDJCommands

@main
enum AutoDJCLI {
    // An explicit async entry point: a top-level `await AutoDJ.main()` can resolve to
    // swift-argument-parser's synchronous main under Xcode, which refuses an async root command.
    static func main() async {
        await AutoDJ.main()
    }
}
