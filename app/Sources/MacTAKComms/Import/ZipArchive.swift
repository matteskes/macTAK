// ZipArchive.swift — just enough zip to read an ATAK data package (G3.2b).
//
// Foundation has no zip reader, and commo carries none. This one reads the
// central directory and inflates entries with the Compression framework
// (COMPRESSION_ZLIB is raw DEFLATE, zip's method 8). It refuses what a data
// package never needs and a hostile one might use: zip64, encryption,
// methods other than stored and deflate, entries that overlap the central
// directory, and any entry past the caller's size cap. The cap holds against
// the bytes actually inflated, not the size the header claims, and every
// entry's CRC-32 is checked.

import Compression
import Foundation

public struct ZipError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// The whole archive, read once: a data package is small, and the caller
    /// caps the file before it gets here.
    let data: Data
    let entries: [Entry]

    private static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    private static let centralHeader: UInt32 = 0x0201_4b50
    private static let localHeader: UInt32 = 0x0403_4b50
    private static let stored: UInt16 = 0, deflated: UInt16 = 8

    init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        guard let eocd = Self.findEndOfCentralDirectory(bytes) else {
            throw ZipError("not a zip archive (no end of central directory)")
        }
        let disk = Self.u16(bytes, eocd + 4), cdDisk = Self.u16(bytes, eocd + 6)
        let count = Int(Self.u16(bytes, eocd + 10))
        let cdSize = Int(Self.u32(bytes, eocd + 12)), cdOffset = Int(Self.u32(bytes, eocd + 16))
        guard disk == 0, cdDisk == 0 else { throw ZipError("multi-disk zip archives are not supported") }
        guard count != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else {
            throw ZipError("zip64 archives are not supported")
        }
        guard cdOffset + cdSize <= eocd else { throw ZipError("central directory runs past its end record") }

        var entries: [Entry] = []
        var at = cdOffset
        for _ in 0..<count {
            guard at + 46 <= cdOffset + cdSize, Self.u32(bytes, at) == Self.centralHeader else {
                throw ZipError("malformed central directory")
            }
            let flags = Self.u16(bytes, at + 8), method = Self.u16(bytes, at + 10)
            let crc = Self.u32(bytes, at + 16)
            let compressed = Self.u32(bytes, at + 20), size = Self.u32(bytes, at + 24)
            let nameLength = Int(Self.u16(bytes, at + 28)), extraLength = Int(Self.u16(bytes, at + 30))
            let commentLength = Int(Self.u16(bytes, at + 32))
            let offset = Self.u32(bytes, at + 42)
            let next = at + 46 + nameLength + extraLength + commentLength
            guard next <= cdOffset + cdSize else { throw ZipError("malformed central directory") }
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else {
                throw ZipError("zip64 entries are not supported")
            }
            // Names are UTF-8 when flagged (bit 11) and, in every package ATAK
            // writes, ASCII otherwise. A name that isn't valid UTF-8 is refused
            // rather than decoded lossily into something the checks never saw.
            guard let name = String(bytes: bytes[(at + 46)..<(at + 46 + nameLength)], encoding: .utf8) else {
                throw ZipError("an entry name is not valid UTF-8")
            }
            if flags & 0x0001 != 0 { throw ZipError("encrypted entries are not supported: \(name)") }
            entries.append(Entry(name: name, method: method, crc32: crc, compressedSize: Int(compressed),
                                 size: Int(size), localHeaderOffset: Int(offset)))
            at = next
        }
        self.entries = entries
    }

    /// The entry's bytes, inflated, refused past `limit` bytes.
    func contents(of entry: Entry, limit: Int) throws -> Data {
        let bytes = data
        guard entry.size <= limit else {
            throw ZipError("\(entry.name) exceeds \(limit) bytes")
        }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == Self.localHeader else {
            throw ZipError("\(entry.name): malformed local header")
        }
        let start = header + 30 + Int(Self.u16(bytes, header + 26)) + Int(Self.u16(bytes, header + 28))
        guard start + entry.compressedSize <= bytes.count else {
            throw ZipError("\(entry.name) runs past the end of the archive")
        }
        let raw = bytes.subdata(in: (bytes.startIndex + start)..<(bytes.startIndex + start + entry.compressedSize))
        let out: Data
        switch entry.method {
        case Self.stored:
            guard raw.count == entry.size else { throw ZipError("\(entry.name): stored size mismatch") }
            out = raw
        case Self.deflated:
            out = try Self.inflate(raw, expected: entry.size, name: entry.name)
        default:
            throw ZipError("\(entry.name): compression method \(entry.method) is not supported")
        }
        guard Self.crc32(out) == entry.crc32 else { throw ZipError("\(entry.name): CRC mismatch") }
        return out
    }

    // MARK: - details

    /// Inflates into a buffer one byte larger than the declared size, so an
    /// entry that lies about its size fills the extra byte and is refused.
    private static func inflate(_ raw: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 { return Data() }
        var out = Data(count: expected + 1)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected + 1,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else {
            throw ZipError("\(name): inflated to \(written == expected + 1 ? "more than" : "\(written) of") \(expected) declared bytes")
        }
        return out.prefix(expected)
    }

    private static func findEndOfCentralDirectory(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        let lowest = max(0, b.count - 22 - 0xFFFF)   // the comment is at most 64 KiB
        var at = b.count - 22
        while at >= lowest {
            if u32(b, at) == endOfCentralDirectory, at + 22 + Int(u16(b, at + 20)) == b.count { return at }
            at -= 1
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { UInt32(u16(b, at)) | UInt32(u16(b, at + 2)) << 16 }
    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        UInt16(d[d.startIndex + at]) | UInt16(d[d.startIndex + at + 1]) << 8
    }
    private static func u32(_ d: Data, _ at: Int) -> UInt32 { UInt32(u16(d, at)) | UInt32(u16(d, at + 2)) << 16 }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
