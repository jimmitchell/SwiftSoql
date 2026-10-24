import AppKit
import Foundation
import Testing
@testable import SwiftSoql

struct SchemaExportTests {
    private func layout() throws -> SchemaLayout {
        let json = #"""
        {"name":"Contact","fields":[{"name":"Id","type":"id"},{"name":"LastName","type":"string","nameField":true},
          {"name":"AccountId","type":"reference","referenceTo":["Account"]},{"name":"ReportsToId","type":"reference","referenceTo":["Contact"]}],
         "childRelationships":[{"childSObject":"Case","field":"ContactId"}]}
        """#
        let describe = SObjectDescribe(json: try #require(try JSONValue.parse(Data(json.utf8)).object))
        return SchemaLayout(describe: describe, fieldMode: .all, hideSystemChildren: true, visibleSize: .zero)
    }

    @Test func layoutHasParentsChildrenAndSelfReference() throws {
        let layout = try layout()
        #expect(layout.parents.map(\.name) == ["Account"])
        #expect(layout.children.map(\.name) == ["Case"])
        #expect(layout.lines.count == 3)
        #expect(layout.boxes.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= layout.size.width })
    }

    @Test func exportsPDFAndPNG() throws {
        let layout = try layout()
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdf = dir.appending(path: "diagram.pdf")
        try SchemaExport.writePDF(layout, icon: { _ in nil }, to: pdf)
        let document = try #require(CGPDFDocument(pdf as CFURL))
        #expect(document.numberOfPages == 1)
        let page = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(page.width == layout.size.width && page.height == layout.size.height)

        let png = dir.appending(path: "diagram.png")
        try SchemaExport.writePNG(layout, icon: { _ in nil }, to: png)
        let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: png)))
        #expect(image.pixelsWide == Int(layout.size.width * 2), "PNGs are exported at 2x")
    }
}
