import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
@ViewBuilder
func editorShell<Content: View>(
    title: String?,
    width: CGFloat?,
    height: CGFloat?,
    saveTitle: String = "Save",
    autoSave: Bool = false,
    trailingActions: Bool = false,
    @ViewBuilder content: () -> Content,
    save: @escaping @MainActor () async -> Void,
    cancel: @escaping () -> Void
) -> some View {
    VStack(spacing: 0) {
        if let title {
            HStack {
                Text(title).font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding()
        }
        content()
        if !autoSave {
            Divider()
            HStack {
                if trailingActions { Spacer() }
                Button(FeatureL10n.text(.historyCancel)) { cancel() }.keyboardShortcut(.cancelAction)
                if !trailingActions { Spacer() }
                Button(saveTitle) { Task { await save() } }
                    .buttonStyle(.glassProminent).tint(.blue).keyboardShortcut(.defaultAction)
            }.padding()
        }
    }.frame(width: width, height: height)
}

func copyToPasteboard(_ value: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = value
    #endif
}
