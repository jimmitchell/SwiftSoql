import Compression
import Foundation

/// Writes a zip archive of in-memory files, deflating each one that gets smaller for it. No
/// Zip64, so the archive must stay under 4 GB and 65,535 files.
nonisolated enum Zip {
    struct Entry {
        var path: String
        var data: Data
    }

    static func archive(_ entries: [Entry], modified: Date = Date()) -> Data {
        let (time, date) = dosTimeAndDate(modified)
        var out = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let deflated = deflate(entry.data)
            let stored = deflated ?? entry.data
            let crc = crc32(entry.data)
            // Fields shared by the local header and the central directory record: version
            // needed, flags (bit 11: UTF-8 names), method, time, date, CRC and sizes.
            var common = Data()
            common.append(le: UInt16(20))
            common.append(le: UInt16(0x0800))
            common.append(le: UInt16(deflated == nil ? 0 : 8))
            common.append(le: time)
            common.append(le: date)
            common.append(le: crc)
            common.append(le: UInt32(stored.count))
            common.append(le: UInt32(entry.data.count))
            common.append(le: UInt16(name.count))
            common.append(le: UInt16(0))

            directory.append(le: UInt32(0x0201_4b50))
            directory.append(le: UInt16(20))
            directory.append(common)
            directory.append(le: UInt16(0))
            directory.append(le: UInt16(0))
            directory.append(le: UInt16(0))
            directory.append(le: UInt32(0))
            directory.append(le: UInt32(out.count))
            directory.append(name)

            out.append(le: UInt32(0x0403_4b50))
            out.append(common)
            out.append(name)
            out.append(stored)
        }
        let directoryOffset = out.count
        out.append(directory)
        out.append(le: UInt32(0x0605_4b50))
        out.append(le: UInt16(0))
        out.append(le: UInt16(0))
        out.append(le: UInt16(entries.count))
        out.append(le: UInt16(entries.count))
        out.append(le: UInt32(directory.count))
        out.append(le: UInt32(directoryOffset))
        out.append(le: UInt16(0))
        return out
    }

    /// Raw deflate of `data`, or nil when that wouldn't make it smaller.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var buffer = [UInt8](repeating: 0, count: data.count)
        let size = data.withUnsafeBytes { source in
            compression_encode_buffer(&buffer, buffer.count, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return size == 0 ? nil : Data(buffer.prefix(size))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }

    /// MS-DOS time and date, in local time, as zip headers store them.
    private static func dosTimeAndDate(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
        let day = max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

private extension Data {
    nonisolated mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
