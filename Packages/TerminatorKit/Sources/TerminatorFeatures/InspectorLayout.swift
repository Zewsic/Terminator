import SwiftUI

/// Presents an inspector above the full-width workspace without changing its layout.
struct InspectorLayout<Content: View, Inspector: View>: View {
    private let content: Content
    private let inspector: Inspector?
    private let isInspectorPresented: Bool?
    private let onContentInteraction: (() -> Void)?
    private let inspectorWidth: CGFloat

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder inspector: () -> Inspector?,
        inspectorWidth: CGFloat = 540,
        isInspectorPresented: Bool? = nil,
        onContentInteraction: (() -> Void)? = nil
    ) {
        self.content = content()
        self.inspector = inspector()
        self.inspectorWidth = inspectorWidth
        self.isInspectorPresented = isInspectorPresented
        self.onContentInteraction = onContentInteraction
    }

    var body: some View {
        let showsInspector = isInspectorPresented ?? (inspector != nil)
        ZStack(alignment: .trailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsInspector {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onContentInteraction?() }
                    .zIndex(0.5)
            }

            if showsInspector, let inspector {
                inspector
                    .frame(width: inspectorWidth)
                    .frame(maxHeight: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.24), value: showsInspector)
        .animation(.snappy(duration: 0.24), value: inspectorWidth)
    }
}
