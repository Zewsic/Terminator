import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct PrivateKeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
