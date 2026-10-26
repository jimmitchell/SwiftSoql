import Compression
import Foundation
import Testing
@testable import SwiftSoql

struct XLSXTests {
    /// The files in a zip archive, read from its central directory.
    static func unzip(_ archive: Data) throws -> [String: Data] {
        let bytes = [UInt8](archive)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let end = bytes.count - 22
        #expect(u32(end) == 0x0605_4b50)
        var files: [String: Data] = [:]
        var record = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            #expect(u32(record) == 0x0201_4b50)
            let method = u16(record + 10), crc = u32(record + 16), size = u32(record + 20), length = u32(record + 24)
            let nameLength = u16(record + 28), local = u32(record + 42)
            let name = String(decoding: bytes[(record + 46)..<(record + 46 + nameLength)], as: UTF8.self)
            #expect(u32(local) == 0x0403_4b50)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            var data = Data(bytes[start..<(start + size)])
            if method == 8 {
                var buffer = [UInt8](repeating: 0, count: length)
                let decoded = data.withUnsafeBytes { compression_decode_buffer(&buffer, length, $0.bindMemory(to: UInt8.self).baseAddress!, size, nil, COMPRESSION_ZLIB) }
                #expect(decoded == length)
                data = Data(buffer)
            } else {
                #expect(method == 0)
            }
            #expect(Int(Zip.crc32(data)) == crc, "CRC of \(name)")
            files[name] = data
            record += 46 + nameLength + u16(record + 30) + u16(record + 32)
        }
        return files
    }

    @Test func crc32() {
        #expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func zipRoundTrips() throws {
        let big = Data(String(repeating: "deflate me ", count: 1000).utf8)
        let files = try Self.unzip(Zip.archive([.init(path: "a/big.txt", data: big), .init(path: "tiny", data: Data("x".utf8)), .init(path: "empty", data: Data())]))
        #expect(files == ["a/big.txt": big, "tiny": Data("x".utf8), "empty": Data()])
    }

    @Test func sheetNamesAreValidAndUnique() {
        let long = "ns__A_Very_Long_Custom_Object_Name__ChangeEvent"
        #expect(XLSX.sheetNames(["Objects", "objects", long, long, "a/b:c", "'quoted'", "History", ""]) == [
            "Objects", "objects (2)", "ns__A_Very_Long_Custom_Object_N", "ns__A_Very_Long_Custom_Obje (2)", "a_b_c", "quoted", "History (2)", "Sheet",
        ])
    }

    @Test func columnLetters() {
        #expect([0, 25, 26, 27, 701, 702].map(XLSX.column) == ["A", "Z", "AA", "AB", "ZZ", "AAA"])
    }

    @Test func escapesTextAndDropsControlCharacters() {
        #expect(XLSX.escaped("a<b & \"c\"\u{1}\td\n") == "a&lt;b &amp; &quot;c&quot;\td\n")
    }

    @Test func workbookPartsAreWellFormed() throws {
        let sheets = XLSX.sheetNames(["Index", "Tom's"])
        let data = XLSX.workbook([
            .init(name: sheets[0], header: ["Name", "Count"], rows: [[.link("Tom's", sheet: sheets[1]), .number(2)]]),
            .init(name: sheets[1], header: ["A", "B"], rows: [[.text(" spaced\nlines "), .text("=1+1")], [.text("<x>")]]),
        ])
        let files = try Self.unzip(data)
        #expect(Set(files.keys) == ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"])
        for (name, part) in files {
            #expect(throws: Never.self, "\(name) is well-formed XML") { try XMLDocument(data: part) }
        }
        let workbook = String(decoding: try #require(files["xl/workbook.xml"]), as: UTF8.self)
        #expect(workbook.contains("<sheet name=\"Tom's\" sheetId=\"2\" r:id=\"rId2\"/>"))
        #expect(workbook.contains("'Tom''s'!$A$1:$B$3"))
        let index = String(decoding: try #require(files["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        #expect(index.contains("<hyperlink ref=\"A2\" location=\"'Tom''s'!A1\" display=\"Tom's\"/>"))
        #expect(index.contains("<c r=\"B2\"><v>2</v></c>"))
        let second = String(decoding: try #require(files["xl/worksheets/sheet2.xml"]), as: UTF8.self)
        #expect(second.contains("<t xml:space=\"preserve\"> spaced\nlines </t>"))
        #expect(second.contains("<t>=1+1</t>"), "Formula-like text stays text")
        #expect(second.contains("<autoFilter ref=\"A1:B3\"/>"))
    }
}
