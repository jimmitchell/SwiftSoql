import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let soql = UTType(filenameExtension: "soql", conformingTo: .plainText) ?? .plainText
    static let apex = UTType(filenameExtension: "apex", conformingTo: .plainText) ?? .plainText
}

/// A query or anonymous Apex saved as a text file, as SoqlXplorer does.
struct CodeDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.soql, .apex, .plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Opens and saves the query or Apex in an explorer window, when the File menu asks.
struct CodeFileHandling: ViewModifier {
    @Bindable var model: ExplorerModel

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $model.isOpeningFile, allowedContentTypes: CodeDocument.readableContentTypes) { result in
                do {
                    let url = try result.get()
                    let text = try String(contentsOf: url, encoding: .utf8)
                    if url.pathExtension.lowercased() == "apex" {
                        model.apex.code = text
                        model.workspace = .apex
                    } else {
                        model.newTab(soql: text)
                    }
                } catch {
                    model.error = DisplayedError("Unable to open the file", error)
                }
            }
            .fileExporter(
                isPresented: $model.isSavingFile,
                document: CodeDocument(text: model.workspace == .apex ? model.apex.code : model.soql),
                contentType: model.workspace == .apex ? .apex : .soql,
                defaultFilename: model.workspace == .apex ? "Anonymous Apex" : "Query"
            ) { result in
                if case .failure(let error) = result {
                    model.error = DisplayedError("Unable to save the file", error)
                }
            }
    }
}
