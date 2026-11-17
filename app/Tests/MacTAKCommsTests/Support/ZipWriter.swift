// Writes zip archives for the import tests, including hostile ones: any
// entry name, a false size or CRC, the encryption flag. Entries are stored
// or deflated (Compression's COMPRESSION_ZLIB is raw DEFLATE).

import Compression
import Foundation
@testable import MacTAKComms

struct ZipWriter {
    struct Entry {
        var name: String
        var data: Data
        var deflate = true
        var flags: UInt16 = 0x0800              // names are UTF-8
        var declaredSize: Int?                  // nil: the true size
        var crc: UInt32?                        // nil: the true CRC-32
    }

    var entries: [Entry] = []

    mutating func add(_ name: String, _ data: Data, deflate: Bool = true) {
        entries.append(Entry(name: name, data: data, deflate: deflate))
    }

    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    func archive() -> Data {
        var out = Data(), central = Data()
        for e in entries {
            let body = e.deflate ? Self.deflate(e.data) : e.data
            let method: UInt16 = e.deflate ? 8 : 0
            let crc = e.crc ?? ZipArchive.crc32(e.data)
            let size = UInt32(e.declaredSize ?? e.data.count)
            let name = Data(e.name.utf8)
            let offset = UInt32(out.count)
            out.u32(0x0403_4b50); out.u16(20); out.u16(e.flags); out.u16(method); out.u16(0); out.u16(0)
            out.u32(crc); out.u32(UInt32(body.count)); out.u32(size); out.u16(UInt16(name.count)); out.u16(0)
            out += name; out += body
            central.u32(0x0201_4b50); central.u16(20); central.u16(20); central.u16(e.flags); central.u16(method)
            central.u16(0); central.u16(0); central.u32(crc); central.u32(UInt32(body.count)); central.u32(size)
            central.u16(UInt16(name.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
            central.u32(0); central.u32(offset); central += name
        }
        let cdOffset = UInt32(out.count)
        out += central
        out.u32(0x0605_4b50); out.u16(0); out.u16(0); out.u16(UInt16(entries.count)); out.u16(UInt16(entries.count))
        out.u32(UInt32(central.count)); out.u32(cdOffset); out.u16(0)
        return out
    }

    private static func deflate(_ data: Data) -> Data {
        if data.isEmpty { return Data([0x03, 0x00]) }   // an empty final block
        var out = Data(count: data.count + 1024)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0, "deflate failed")
        return out.prefix(n)
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
}
