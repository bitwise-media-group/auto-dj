// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import CommonCrypto
import Foundation

/// Decrypts and encrypts SQLCipher 4 database files (the format of Rekordbox's master.db) with
/// CommonCrypto, so the plain SQLite file can be opened with the system SQLite (port of
/// internal/sqlcipher).
///
/// SQLCipher 4 defaults: the key is a passphrase run through PBKDF2-HMAC-SHA512 (256000
/// iterations) with the first 16 bytes of the file as salt; the HMAC key is PBKDF2(encryption
/// key, salt XOR 0x3a, 2 iterations). Pages are 4096 bytes and keep 80 reserve bytes at the end
/// (IV 16 + HMAC-SHA512 64). Each page is AES-256-CBC encrypted, then authenticated with
/// HMAC-SHA512 over ciphertext ‖ IV ‖ page number (uint32 little-endian). Page 1 carries the
/// salt in place of the SQLite header string.
public enum SQLCipher {
    public static let pageSize = 4096
    public static let reserve = ivSize + hmacSize
    public static let saltSize = 16
    static let ivSize = 16
    static let hmacSize = 64
    static let keySize = 32
    static let kdfIter: UInt32 = 256_000
    static let fastKDF: UInt32 = 2
    static let hmacMask: UInt8 = 0x3A
    static let headerSize = 16
    static let sqliteHeader = Array("SQLite format 3\u{0}".utf8)

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case hmac(page: Int)
        case layout(String)
        case crypto(String)

        public var description: String {
            switch self {
            case .hmac(let p): "sqlcipher: HMAC check failed (wrong key or corrupt file) (page \(p))"
            case .layout(let s), .crypto(let s): "sqlcipher: \(s)"
            }
        }
    }

    struct Keys {
        let enc: [UInt8]
        let mac: [UInt8]
    }

    private static let kdfLock = NSLock()
    nonisolated(unsafe) private static var kdfCache: [String: Keys] = [:]

    static func pbkdf2(_ pass: [UInt8], _ salt: [UInt8], _ rounds: UInt32) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: keySize)
        let st = pass.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pass.count) { pp in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pp, pass.count, salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds, &out, keySize)
            }
        }
        if st != kCCSuccess { throw Failure.crypto("PBKDF2 failed (\(st))") }
        return out
    }

    /// Runs the (slow) passphrase KDF once per key and salt per process.
    static func deriveKeys(_ pass: String, _ salt: [UInt8]) throws -> Keys {
        guard salt.count == saltSize else { throw Failure.layout("salt must be \(saltSize) bytes") }
        let id = pass + "\u{0}" + salt.map { String(format: "%02x", $0) }.joined()
        kdfLock.lock()
        defer { kdfLock.unlock() }
        if let k = kdfCache[id] { return k }
        let enc = try pbkdf2(Array(pass.utf8), salt, kdfIter)
        let msalt = salt.map { $0 ^ hmacMask }
        let mac = try pbkdf2(enc, msalt, fastKDF)
        let k = Keys(enc: enc, mac: mac)
        kdfCache[id] = k
        return k
    }

    static func pageHMAC(_ key: [UInt8], _ data: UnsafeRawBufferPointer, _ pgno: UInt32) -> [UInt8] {
        var ctx = CCHmacContext()
        CCHmacInit(&ctx, CCHmacAlgorithm(kCCHmacAlgSHA512), key, key.count)
        CCHmacUpdate(&ctx, data.baseAddress, data.count)
        var n = pgno.littleEndian
        withUnsafeBytes(of: &n) { CCHmacUpdate(&ctx, $0.baseAddress, 4) }
        var out = [UInt8](repeating: 0, count: hmacSize)
        CCHmacFinal(&ctx, &out)
        return out
    }

    static func aes(
        _ op: Int, key: [UInt8], iv: UnsafeRawBufferPointer, input: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer
    ) throws {
        var moved = 0
        let st = CCCrypt(
            CCOperation(op), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, iv.baseAddress,
            input.baseAddress, input.count, output.baseAddress, output.count, &moved)
        if st != kCCSuccess || moved != input.count { throw Failure.crypto("AES failed (\(st))") }
    }

    /// The KDF salt (the first 16 bytes) of an encrypted database.
    public static func readSalt(_ path: String) throws -> [UInt8] {
        guard let h = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? h.close() }
        let d = try h.read(upToCount: saltSize) ?? Data()
        guard d.count == saltSize else { throw Failure.layout("reading salt of \(path): short file") }
        return Array(d)
    }

    static func readPages(_ path: String) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.isEmpty || data.count % pageSize != 0 {
            throw Failure.layout(
                "\(path) is \(data.count) bytes, not a whole number of \(pageSize)-byte pages")
        }
        return data
    }

    /// Writes the plain SQLite database for the SQLCipher file src to dst. Every page's HMAC is
    /// checked. The plain file keeps the 80 reserve bytes per page (its header says so), filled
    /// with the page's IV and HMAC as SQLCipher itself does.
    public static func decrypt(src: String, dst: String, key: String) throws {
        let data = try readPages(src)
        let k = try deriveKeys(key, Array(data.prefix(saltSize)))
        var out = Data(count: data.count)
        let size = pageSize - reserve
        try data.withUnsafeBytes { inAll in
            try out.withUnsafeMutableBytes { outAll in
                for p in 0..<(data.count / pageSize) {
                    let pgno = UInt32(p + 1)
                    let base = p * pageSize
                    let page = UnsafeRawBufferPointer(rebasing: inAll[base..<base + pageSize])
                    if !page.contains(where: { $0 != 0 }) { continue }  // never written: stays zero
                    var off = 0
                    if pgno == 1 {
                        off = headerSize
                        for (i, b) in sqliteHeader.enumerated() { outAll[base + i] = b }
                    }
                    let want = pageHMAC(
                        k.mac, UnsafeRawBufferPointer(rebasing: page[off..<size + ivSize]), pgno)
                    let mac = page[(size + ivSize)...]
                    if !zip(want, mac).allSatisfy({ $0 == $1 }) { throw Failure.hmac(page: Int(pgno)) }
                    let iv = UnsafeRawBufferPointer(rebasing: page[size..<size + ivSize])
                    try aes(
                        kCCDecrypt, key: k.enc, iv: iv,
                        input: UnsafeRawBufferPointer(rebasing: page[off..<size]),
                        output: UnsafeMutableRawBufferPointer(rebasing: outAll[base + off..<base + size]))
                    for i in 0..<ivSize { outAll[base + size + i] = iv[i] }
                    for i in 0..<hmacSize { outAll[base + size + ivSize + i] = want[i] }
                }
            }
        }
        if Int(out[20]) != reserve {
            throw Failure.layout(
                "decrypted header of \(src) has reserve \(out[20]), expected \(reserve)")
        }
        try out.write(to: URL(fileURLWithPath: dst))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst)
    }

    /// Writes src (a plain SQLite database with 4096-byte pages and 80 reserve bytes) to dst as
    /// a SQLCipher 4 file keyed with key and salt. Each page's IV is iv(pgno) when that returns
    /// 16 bytes, random otherwise: re-encrypting a decrypted file with its original IVs gives the
    /// original file byte for byte.
    public static func encrypt(
        src: String, dst: String, key: String, salt: [UInt8], iv: ((UInt32) -> [UInt8]?)? = nil
    ) throws {
        let data = try readPages(src)
        guard Array(data.prefix(headerSize)) == sqliteHeader else {
            throw Failure.layout("\(src) is not a plain SQLite database")
        }
        guard Int(data[20]) == reserve else {
            throw Failure.layout("\(src) has \(data[20]) reserve bytes per page, need \(reserve)")
        }
        let ps = Int(data[16]) << 8 | Int(data[17])
        guard ps == pageSize else { throw Failure.layout("\(src) has page size \(ps), need \(pageSize)") }
        let k = try deriveKeys(key, salt)
        var out = Data(count: data.count)
        let size = pageSize - reserve
        try data.withUnsafeBytes { inAll in
            try out.withUnsafeMutableBytes { outAll in
                for p in 0..<(data.count / pageSize) {
                    let pgno = UInt32(p + 1)
                    let base = p * pageSize
                    var off = 0
                    if pgno == 1 {
                        off = headerSize
                        for (i, b) in salt.enumerated() { outAll[base + i] = b }
                    }
                    var v = iv?(pgno) ?? []
                    if v.count != ivSize {
                        v = [UInt8](repeating: 0, count: ivSize)
                        if SecRandomCopyBytes(kSecRandomDefault, ivSize, &v) != errSecSuccess {
                            throw Failure.crypto("no random bytes")
                        }
                    }
                    for i in 0..<ivSize { outAll[base + size + i] = v[i] }
                    try v.withUnsafeBytes { ivp in
                        try aes(
                            kCCEncrypt, key: k.enc, iv: ivp,
                            input: UnsafeRawBufferPointer(rebasing: inAll[base + off..<base + size]),
                            output: UnsafeMutableRawBufferPointer(rebasing: outAll[base + off..<base + size]))
                    }
                    let mac = pageHMAC(
                        k.mac,
                        UnsafeRawBufferPointer(rebasing: outAll[base + off..<base + size + ivSize]), pgno)
                    for i in 0..<hmacSize { outAll[base + size + ivSize + i] = mac[i] }
                }
            }
        }
        try writeSync(dst, out)
    }

    /// A lookup of each page's IV in the encrypted file at path (for `encrypt(iv:)`).
    public static func pageIVs(_ path: String) throws -> (UInt32) -> [UInt8]? {
        let data = try readPages(path)
        return { pgno in
            let p = Int(pgno) - 1
            if p < 0 || (p + 1) * pageSize > data.count { return nil }
            let start = p * pageSize + pageSize - reserve
            return Array(data[start..<start + ivSize])
        }
    }

    static func writeSync(_ path: String, _ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd < 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        defer { close(fd) }
        try data.withUnsafeBytes { b in
            var done = 0
            while done < b.count {
                let n = write(fd, b.baseAddress! + done, b.count - done)
                if n <= 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
                done += n
            }
        }
        if fsync(fd) != 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
    }

    // ---------------------------------------------------------------- key

    /// master.db's key as pyrekordbox ships it: base85 (RFC 1924 alphabet), XORed with blobKey,
    /// zlib-compressed.
    static let keyBlob =
        "PN_Pq^*N>(JYe*u^8;Yg76HuZ<mR13S?=>)b9;DpoTXV(6ItkU`}8*m6tx_I{Solh_N#dfe{v="
    static let blobKey = Array("657f48f84c437cc1".utf8)
    /// How every Rekordbox 6/7 master.db key starts.
    static let keyPrefix = "402fd"

    /// master.db's key: REKORDBOX_DB_KEY when set, else the known key.
    public static func rekordboxKey() throws -> String {
        if let k = ProcessInfo.processInfo.environment["REKORDBOX_DB_KEY"], !k.isEmpty {
            guard k.hasPrefix(keyPrefix) else {
                throw Failure.layout("REKORDBOX_DB_KEY doesn't look like a Rekordbox database key")
            }
            return k
        }
        return try deobfuscate(keyBlob)
    }

    static func deobfuscate(_ blob: String) throws -> String {
        var data = try b85decode(blob)
        for i in data.indices { data[i] ^= blobKey[i % blobKey.count] }
        return String(decoding: try Data(data).zlibInflated(), as: UTF8.self)
    }

    static let b85alphabet = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~".utf8)

    /// Python's base64.b85decode (RFC 1924 alphabet, short final group padded with '~').
    static func b85decode(_ s: String) throws -> [UInt8] {
        var rev = [Int](repeating: -1, count: 256)
        for (i, c) in b85alphabet.enumerated() { rev[Int(c)] = i }
        var bytes = Array(s.utf8)
        let pad = (5 - bytes.count % 5) % 5
        bytes += [UInt8](repeating: UInt8(ascii: "~"), count: pad)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count / 5 * 4)
        for i in stride(from: 0, to: bytes.count, by: 5) {
            var acc: UInt64 = 0
            for c in bytes[i..<i + 5] {
                let v = rev[Int(c)]
                if v < 0 { throw Failure.layout("bad base85 character \(c)") }
                acc = acc * 85 + UInt64(v)
            }
            if acc > 0xFFFF_FFFF { throw Failure.layout("base85 overflow") }
            out += [UInt8(acc >> 24 & 0xFF), UInt8(acc >> 16 & 0xFF), UInt8(acc >> 8 & 0xFF), UInt8(acc & 0xFF)]
        }
        return Array(out.dropLast(pad))
    }
}

extension Data {
    /// Inflates a zlib stream (RFC 1950): Foundation's .zlib is raw deflate, so the 2-byte
    /// header and the Adler-32 trailer are dropped first.
    func zlibInflated() throws -> Data {
        guard count > 6 else { throw AutoDJError("zlib stream too short") }
        return try (subdata(in: 2..<(count - 4)) as NSData).decompressed(using: .zlib) as Data
    }
}
