// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Paths, the cue template and the rule thresholds (port of internal/config).
///
/// Every threshold in `Rules.default` was tuned against Deavon's 51 hand-cued tracks on
/// 2026-10-14 (see docs/decisions/0003-cue-placement-rules.md for what each one does and how
/// it scored). Change them in one place and re-run `auto-dj evaluate` to see the effect before
/// writing anything.
public enum Config {
    // ---------------------------------------------------------------- paths

    static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Holds master.db and share/.
    public static var defaultRBDir: String {
        (home as NSString).appendingPathComponent("Library/Pioneer/rekordbox")
    }

    /// The feature cache and plan output folder (AUTO_DJ_WORK overrides it).
    public static var defaultWorkDir: String {
        if let w = ProcessInfo.processInfo.environment["AUTO_DJ_WORK"], !w.isEmpty { return w }
        return (home as NSString).appendingPathComponent(".cache/auto-dj")
    }

    /// An optional audio path remap for a library mounted somewhere else (e.g. a VM):
    /// AUTO_DJ_PATH_MAP="/Users/me/Music=/mnt/Music;/Volumes/USB=/mnt/usb".
    nonisolated(unsafe) public static var pathMap: [(String, String)] = parsePathMap(
        ProcessInfo.processInfo.environment["AUTO_DJ_PATH_MAP"] ?? "")

    static func parsePathMap(_ s: String) -> [(String, String)] {
        s.split(separator: ";", omittingEmptySubsequences: false).compactMap { p in
            let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        }
    }

    /// Where Cloud Library Sync tracks live. Their FolderPath is relative to the cloud drive's
    /// rekordbox folder ('/contents_<device id>/artist/album/file'); the files are in e.g.
    /// ~/Library/CloudStorage/Dropbox-<team>/<member>/rekordbox. AUTO_DJ_CLOUD_DIR overrides.
    nonisolated(unsafe) public static var cloudDirs: [String] = findCloudDirs()

    static func findCloudDirs() -> [String] {
        if let d = ProcessInfo.processInfo.environment["AUTO_DJ_CLOUD_DIR"], !d.isEmpty { return [d] }
        let fm = FileManager.default
        let storage = (home as NSString).appendingPathComponent("Library/CloudStorage")
        var set = Set<String>()
        for a in (try? fm.contentsOfDirectory(atPath: storage)) ?? [] {
            let d1 = (storage as NSString).appendingPathComponent(a)
            let rb1 = (d1 as NSString).appendingPathComponent("rekordbox")
            if isDir(rb1) { set.insert(rb1) }
            for b in (try? fm.contentsOfDirectory(atPath: d1)) ?? [] {
                let rb2 = ((d1 as NSString).appendingPathComponent(b) as NSString).appendingPathComponent(
                    "rekordbox")
                if isDir(rb2) { set.insert(rb2) }
            }
        }
        return set.sorted()
    }

    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    /// Applies `pathMap`, then resolves Cloud Library Sync paths against `cloudDirs`.
    public static func mapPath(_ path: String) -> String {
        for (src, dst) in pathMap where !path.isEmpty && path.hasPrefix(src) {
            return dst + path.dropFirst(src.count)
        }
        if path.hasPrefix("/contents_") {
            for d in cloudDirs {
                let p = (d as NSString).appendingPathComponent(String(path.dropFirst()))
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        return path
    }

    /// Expands a leading ~ like the shell.
    public static func expandUser(_ p: String) -> String {
        if p == "~" || p.hasPrefix("~/") { return home + p.dropFirst() }
        return p
    }

    // ---------------------------------------------------------------- template

    /// Maps a slot to Rekordbox's djmdCue.Kind: 0 = memory cue, hot cues A..H = 1,2,3,5,6,7,8,9
    /// (4 is skipped).
    public static let kind: [String: Int] = [
        "MEM": 0, "A": 1, "B": 2, "C": 3, "D": 5, "E": 6, "F": 7, "G": 8, "H": 9,
    ]

    /// One entry of the hot cue template.
    public struct HotSlot: Sendable {
        public let name: String
        public let slot: String
    }

    /// Maps cue names to hot cue slots, in template order. E, F, G are Deavon's personal
    /// mix-pairing notes (other track names); never written by `plan`.
    public static let hotTemplate: [HotSlot] = [
        HotSlot(name: "IN", slot: "A"),
        HotSlot(name: "BRIDGE", slot: "B"),  // a.k.a. the breakdown
        HotSlot(name: "DROP", slot: "C"),  // first drop after the bridge
        HotSlot(name: "OUT", slot: "D"),
        HotSlot(name: "EMERGENCY", slot: "H"),  // active loop in the outro
    ]

    /// `memoryColor`'s names in the order messages show them.
    public static let memoryColorOrder = [
        "START", "IN", "LATE",
        "BASS SWAP", "BASS SWAP IN", "BASS SWAP OUT",
        "DROP", "VOCAL",
        "FILTER", "FILTER IN", "FILTER OUT",
        "JUMP",
        "CUT", "CUT IN", "CUT OUT",
        "SYNC", "SYNC IN", "SYNC OUT",
    ]

    /// djmdCue.Color for memory cues: 0 pink, 1 red, 2 orange, 3 yellow, 4 green, 5 aqua,
    /// 6 blue, 7 purple (one below the djmdColor IDs used for track colours). `set` also
    /// recolours existing memory cues with these names on every track in the playlist.
    public static let memoryColor: [String: Int] = [
        "START": 1, "IN": 1, "LATE": 1,  // red
        "BASS SWAP": 2, "BASS SWAP IN": 2, "BASS SWAP OUT": 2,  // orange
        "DROP": 4,  // green
        "VOCAL": 3,  // yellow
        "FILTER": 7, "FILTER IN": 7, "FILTER OUT": 7,  // purple
        "JUMP": 0,  // pink
        "CUT": 6, "CUT IN": 6, "CUT OUT": 6,  // blue
        "SYNC": 1,  // red
        "SYNC IN": 5, "SYNC OUT": 5,  // aqua
    ]

    /// Old memory cue names `set` renames (memory cues only: OUT stays the D hot cue name).
    static let memoryRename: [String: String] = [
        "FILTER DOWN": "FILTER",
        "LOW PASS": "FILTER",
        "FILTER OUT OUT": "FILTER OUT",
        "FILTER OUT IN": "FILTER IN",
        "OUT": "CUT OUT",
    ]

    /// Memory cues with these words anywhere in the name are renamed, in this order.
    static let memoryRenameWord = [("CUT-OUT", "CUT OUT"), ("CUT-IN", "CUT IN")]

    /// Names `set` renames whatever label follows them; hot cues only get the JUMP one.
    static let memoryRenamePrefix = [("JUMP", "JUMP")]
    static let hotRenamePrefix = [("JUMP", "JUMP")]

    /// Python's str.isspace for one character.
    public static func isSpace(_ r: Unicode.Scalar) -> Bool {
        Text.isSpace(r) || (0x1C...0x1F).contains(r.value)
    }

    /// Python's str.strip().
    public static func strip(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        guard let first = u.firstIndex(where: { !isSpace($0) }) else { return "" }
        let last = u.lastIndex(where: { !isSpace($0) })!
        return String(String.UnicodeScalarView(u[first...last]))
    }

    /// A cue name as compared everywhere: stripped and upper-cased.
    public static func norm(_ s: String) -> String { strip(s).uppercased() }

    /// The name `set --write` gives a cue (the renames, then the words, then the prefixes), or
    /// "" to keep it.
    public static func renameTo(_ name: String, hot: Bool) -> String {
        let n = norm(name)
        if !hot {
            if let to = memoryRename[n] { return to }
            for (w, to) in memoryRenameWord where hasWord(n, w) { return to }
        }
        for (p, to) in hot ? hotRenamePrefix : memoryRenamePrefix where n.hasPrefix(p + " ") {
            return to
        }
        return ""
    }

    /// Whether w occurs in s delimited by whitespace or the ends of s.
    static func hasWord(_ s: String, _ w: String) -> Bool {
        let u = Array(s.unicodeScalars)
        let wu = Array(w.unicodeScalars)
        guard wu.count <= u.count else { return false }
        for j in 0...(u.count - wu.count) where Array(u[j..<j + wu.count]) == wu {
            let before = j == 0 || isSpace(u[j - 1])
            let end = j + wu.count
            let after = end == u.count || isSpace(u[end])
            if before, after { return true }
        }
        return false
    }

    /// The default hot cue colour.
    public static let hotColor = -1

    /// The EMERGENCY loop length (the user uses 32, sometimes 64).
    public static let emergencyLoopBeats = 32
}

/// The folders one run works with.
public struct Paths: Sendable {
    public var rbDir: String
    public var workDir: String

    public init(rbDir: String, workDir: String) {
        self.rbDir = rbDir
        self.workDir = workDir
    }

    func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }

    /// Rekordbox's encrypted database.
    public var masterDB: String { join(rbDir, "master.db") }
    /// Holds the ANLZ analysis files.
    public var shareDir: String { join(rbDir, "share") }
    /// The per-track audio feature cache.
    public var featureDir: String { join(workDir, "features") }
    /// Holds master.db backups, the ledger and the transition cache.
    public var backupDir: String { join((rbDir as NSString).deletingLastPathComponent, "_cue_work") }
    /// The E/G transition cache (pairs).
    public var transitions: String { join(backupDir, "transitions.json") }
    /// Lists the tracks this tool has cued.
    public var ledger: String { join(backupDir, "applied-tracks.json") }
    /// The per-set render cache (PCM chunks keyed by segment parameters).
    public var renderDir: String { join(workDir, "renders") }
    /// Mixed In Key's energy level per audio file (`EnergyTags`).
    public var energyTags: String { join(workDir, "energy-tags.json") }
}

/// The thresholds for the rules. Units: beats (1-based beat index into the Rekordbox grid) and
/// normalised bass level (0 = silence, ~1 = the track's loudest 5% of bass).
public struct Rules: Sendable, Equatable {
    /// IN never earlier than beat 33 (8 bars) unless phrase says so.
    public var inMin = 33
    /// ... and never later than beat 129 (32 bars).
    public var inMax = 129
    /// A breakdown shorter than this = no BRIDGE (user rule).
    public var bridgeMin = 16
    /// A "real" breakdown is >= 64 beats.
    public var bridgeBig = 64
    /// Below this a phrase counts as "no bass".
    public var bassLow = 0.35
    /// A breakdown run continues while bass stays below this.
    public var bassCont = 0.45
    /// Loop / OUT regions must have at least this much bass.
    public var bassPresent = 0.45
    /// EMERGENCY targets ~68 beats before the last beat.
    public var emBack = 68
    /// Preference (in beats) for real Rekordbox phrase starts.
    public var phraseBonus = 8
    /// Bass level after a drop.
    public var dropOn = 0.7
    /// Bass level before a drop.
    public var dropOff = 0.4
    /// Beats of low bass needed before a memory DROP.
    public var dropPre = 32
    public var dropNeedsChorus = true
    /// Minimum bass jump for a fallback BASS SWAP.
    public var bassSwapMin = 0.3

    public init() {}

    /// The tuned thresholds (change them only here; see ADR 0003).
    public static let `default` = Rules()
}
