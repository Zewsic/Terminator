import SwiftUI

/// Keeps the workspace full-width until the user opens an inspector.
struct InspectorLayout<Content: View, Inspector: View>: View {
    private let content: Content
    private let inspector: Inspector?
    private let isInspectorPresented: Bool?
    private let onContentInteraction: (() -> Void)?
    @State private var inspectorWidth: CGFloat = 540
    @State private var resizeStartWidth: CGFloat = 540
    @State private var isResizing = false

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder inspector: () -> Inspector?,
        isInspectorPresented: Bool? = nil,
        onContentInteraction: (() -> Void)? = nil
    ) {
        self.content = content()
        self.inspector = inspector()
        self.isInspectorPresented = isInspectorPresented
        self.onContentInteraction = onContentInteraction
    }

    var body: some View {
        let showsInspector = isInspectorPresented ?? (inspector != nil)
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    if showsInspector { onContentInteraction?() }
                })
            if showsInspector, let inspector {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
                    .contentShape(Rectangle().inset(by: -4))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isResizing {
                                    isResizing = true
                                    resizeStartWidth = inspectorWidth
                                }
                                inspectorWidth = min(max(resizeStartWidth - value.translation.width, 360), 760)
                            }
                            .onEnded { _ in isResizing = false }
                    )
                    .transition(.opacity)
                inspector
                    .frame(width: inspectorWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsInspector)
    }
}
