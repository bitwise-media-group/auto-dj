// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Reads and writes the JSON artifacts (plan.json, set-plan.json, set.json, …) with
/// Foundation's coders: pretty-printed with sorted keys so files diff cleanly.
public enum JSONFile {
    public static func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(v)
    }

    /// Writes v to path, creating the parent folder.
    public static func write<T: Encodable>(_ v: T, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try writeAtomically(encode(v), to: path)
    }

    public static func read<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AutoDJError("\(path): \(error)")
        }
    }
}

/// Writes data to path + ".tmp" and renames it over path, so readers never see a partial file.
public func writeAtomically(_ data: Data, to path: String) throws {
    let tmp = path + ".tmp"
    try data.write(to: URL(fileURLWithPath: tmp))
    if rename(tmp, path) != 0 {
        try? FileManager.default.removeItem(atPath: tmp)
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
}
