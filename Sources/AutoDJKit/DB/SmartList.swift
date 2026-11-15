// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// An intelligent playlist (djmdPlaylist.Attribute 4) stores no tracks: Rekordbox matches the
/// collection against the conditions in djmdPlaylist.SmartList each time it is shown, e.g.
///
///     <NODE Id="-185693195" LogicalOperator="1" AutomaticUpdate="0">
///       <CONDITION PropertyName="counter" Operator="1" ValueUnit="" ValueLeft="" ValueRight=""/>
///     </NODE>
///
/// `whereClause` compiles them to a where clause over djmdContent c. An empty value means
/// none: 0 for numbers, no text, no date or no colour ("Never Played" is counter = '').
enum SmartList {
    struct Condition {
        var property = ""
        var op = 0
        var unit = ""
        var left = ""
        var right = ""
    }

    static let opIs = 1
    static let opIsNot = 2
    static let opGreater = 3
    static let opLess = 4
    static let opInRange = 5
    static let opInLast = 6
    static let opNotInLast = 7
    static let opContains = 8
    static let opNotContains = 9
    static let opStartsWith = 10
    static let opEndsWith = 11

    enum Kind { case text, number, date, colour, myTag }

    static func artistOf(_ col: String) -> String {
        "(select Name from djmdArtist where ID = c.\(col))"
    }

    static let fields: [String: (Kind, String)] = [
        "name": (.text, "c.Title"),
        "artist": (.text, artistOf("ArtistID")),
        "originalArtist": (.text, artistOf("OrgArtistID")),
        "remixedBy": (.text, artistOf("RemixerID")),
        "producer": (.text, artistOf("ComposerID")),
        "album": (.text, "(select Name from djmdAlbum where ID = c.AlbumID)"),
        "albumArtist": (
            .text,
            "(select a.Name from djmdAlbum al join djmdArtist a on a.ID = al.AlbumArtistID "
                + "where al.ID = c.AlbumID)"
        ),
        "genre": (.text, "(select Name from djmdGenre where ID = c.GenreID)"),
        "label": (.text, "(select Name from djmdLabel where ID = c.LabelID)"),
        "key": (.text, "(select ScaleName from djmdKey where ID = c.KeyID)"),
        "comments": (.text, "c.Commnt"),
        "fileName": (.text, "c.FileNameL"),
        "mixName": (.text, "c.Subtitle"),
        "bpm": (.number, "c.BPM / 100.0"),
        "duration": (.number, "c.Length"),  // seconds
        "rating": (.number, "c.Rating"),  // stars, 0-5
        "counter": (.number, "c.DJPlayCount"),
        "year": (.number, "c.ReleaseYear"),
        "stockDate": (.date, "c.StockDate"),  // date added
        "dateCreated": (.date, "c.DateCreated"),
        "dateReleased": (.date, "c.ReleaseDate"),
        "grouping": (.colour, "c.ColorID"),
        "myTag": (.myTag, ""),
    ]

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }

    final class Parser: NSObject, XMLParserDelegate {
        var logic: Int?
        var conditions: [Condition] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes a: [String: String]
        ) {
            if name == "NODE", logic == nil {
                logic = Int(a["LogicalOperator"] ?? "") ?? 0
            } else if name == "CONDITION" {
                conditions.append(
                    Condition(
                        property: a["PropertyName"] ?? "", op: Int(a["Operator"] ?? "") ?? 0,
                        unit: a["ValueUnit"] ?? "", left: a["ValueLeft"] ?? "", right: a["ValueRight"] ?? ""))
            }
        }
    }

    /// Compiles an intelligent playlist's SmartList XML to a where clause over djmdContent c and
    /// its arguments. today anchors "in the last N days / months".
    static func whereClause(_ src: String, today: Date) throws -> (String, [SQLBindable]) {
        let p = Parser()
        let xp = XMLParser(data: Data(src.utf8))
        xp.delegate = p
        if !xp.parse() {
            throw Failure("reading its conditions: \(xp.parserError?.localizedDescription ?? "bad XML")")
        }
        let join: String
        switch p.logic ?? 0 {
        case 1: join = " and "
        case 2: join = " or "
        default: throw Failure("unknown LogicalOperator \(p.logic ?? 0)")
        }
        if p.conditions.isEmpty { throw Failure("it has no conditions") }
        var parts: [String] = []
        var args: [SQLBindable] = []
        for c in p.conditions {
            do {
                let (part, a) = try sql(c, today: today)
                parts.append("(" + part + ")")
                args += a
            } catch {
                throw Failure("condition \(c.property) \(c.op) \"\(c.left)\": \(error)")
            }
        }
        return (parts.joined(separator: join), args)
    }

    static func sql(_ c: Condition, today: Date) throws -> (String, [SQLBindable]) {
        guard let (kind, expr) = fields[c.property] else { throw Failure("unknown property") }
        switch kind {
        case .text:
            return try textSQL("lower(coalesce(\(expr), ''))", c.op, c.left)
        case .number:
            return try numberSQL("coalesce(\(expr), 0)", c)
        case .date:
            return try dateSQL("coalesce(substr(\(expr), 1, 10), '')", c, today)
        case .colour:
            let x = "(case when coalesce(\(expr), '') in ('', '0') then '' else \(expr) end)"
            if c.op == opIs { return (x + " = ?", [c.left]) }
            if c.op == opIsNot { return (x + " <> ?", [c.left]) }
        case .myTag:
            guard var id = Int64(c.left) else { throw Failure("not a My Tag ID") }
            if id < 0 { id += 1 << 32 }  // stored as a signed 32-bit integer
            let has =
                "exists (select 1 from djmdSongMyTag t where t.ContentID = c.ID and t.MyTagID = ? "
                + "and t.rb_local_deleted = 0)"
            if c.op == opIs || c.op == opContains { return (has, [String(id)]) }
            if c.op == opIsNot || c.op == opNotContains { return ("not " + has, [String(id)]) }
        }
        throw Failure("unsupported operator")
    }

    /// Matches x (already lower-cased) case-insensitively, like Rekordbox. Both sides are folded
    /// by SQLite (ASCII only), so they always fold the same way.
    static func textSQL(_ x: String, _ op: Int, _ v: String) throws -> (String, [SQLBindable]) {
        let esc = v.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        switch op {
        case opIs: return (x + " = lower(?)", [v])
        case opIsNot: return (x + " <> lower(?)", [v])
        case opContains: return (x + " like ? escape '\\'", ["%" + esc + "%"])
        case opNotContains: return (x + " not like ? escape '\\'", ["%" + esc + "%"])
        case opStartsWith: return (x + " like ? escape '\\'", [esc + "%"])
        case opEndsWith: return (x + " like ? escape '\\'", ["%" + esc])
        default: throw Failure("unsupported operator")
        }
    }

    static func numberSQL(_ x: String, _ c: Condition) throws -> (String, [SQLBindable]) {
        func num(_ s: String) -> Double? { s.isEmpty ? 0 : Double(s) }
        guard let lo = num(c.left) else { throw Failure("not a number") }
        switch c.op {
        case opIs: return (x + " = ?", [lo])
        case opIsNot: return (x + " <> ?", [lo])
        case opGreater: return (x + " > ?", [lo])
        case opLess: return (x + " < ?", [lo])
        case opInRange:
            guard let hi = num(c.right) else {
                throw Failure("upper bound \"\(c.right)\" is not a number")
            }
            return (x + " between ? and ?", [lo, hi])
        default: throw Failure("unsupported operator")
        }
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    static func isDate(_ s: String) -> Bool {
        s.isEmpty || (s.count == 10 && dayFormat.date(from: s) != nil)
    }

    /// Compares x, a YYYY-MM-DD date or '' when unset, as text. An unset date only matches
    /// "is ''" and "is not <date>".
    static func dateSQL(_ x: String, _ c: Condition, _ today: Date) throws -> (
        String, [SQLBindable]
    ) {
        if [opIs, opIsNot, opGreater, opLess, opInRange].contains(c.op), !isDate(c.left) {
            throw Failure("not a YYYY-MM-DD date")
        }
        switch c.op {
        case opIs: return (x + " = ?", [c.left])
        case opIsNot: return (x + " <> ?", [c.left])
        case opGreater: return (x + " > ?", [c.left])
        case opLess: return (x + " < ? and " + x + " <> ''", [c.left])
        case opInRange:
            if !isDate(c.right) || c.right.isEmpty {
                throw Failure("end \"\(c.right)\" is not a YYYY-MM-DD date")
            }
            return (x + " between ? and ?", [c.left, c.right])
        case opInLast, opNotInLast:
            guard let n = Int(c.left) else { throw Failure("not a number of \(c.unit)s") }
            var comp = DateComponents()
            switch c.unit {
            case "1", "day": comp.day = -n
            case "2", "month": comp.month = -n
            default: throw Failure("unknown unit \"\(c.unit)\"")
            }
            let since = addDate(today, comp)
            let s = dayFormat.string(from: since)
            if c.op == opInLast { return (x + " >= ?", [s]) }
            return (x + " < ? and " + x + " <> ''", [s])
        default: throw Failure("unsupported operator")
        }
    }

    /// Go's time.AddDate: adds years/months/days and normalises overflowing days (Jan 31 + 1
    /// month = Mar 3), unlike Calendar's clamping.
    static func addDate(_ d: Date, _ comp: DateComponents) -> Date {
        let cal = Calendar(identifier: .gregorian)
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        c.month = (c.month ?? 1) + (comp.month ?? 0)
        c.day = (c.day ?? 1) + (comp.day ?? 0)
        // normalise month first, then let the day overflow roll forward
        let y = c.year ?? 2000
        let m0 = (c.month ?? 1) - 1
        var first = DateComponents()
        first.year = y + Num.floorDiv(m0, 12)
        first.month = ((m0 % 12) + 12) % 12 + 1
        first.day = 1
        first.hour = c.hour
        first.minute = c.minute
        first.second = c.second
        let base = cal.date(from: first) ?? d
        return cal.date(byAdding: .day, value: (c.day ?? 1) - 1, to: base) ?? d
    }
}
