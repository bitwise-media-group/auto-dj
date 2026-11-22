// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

@testable import AutoDJKit

/// The checked-in fixtures (next to this file, not bundled).
func fixture(_ name: String) -> String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name).path
}

/// A fresh temporary folder.
func tempDir() throws -> String { try makeTempDir("auto-dj-test-") }
