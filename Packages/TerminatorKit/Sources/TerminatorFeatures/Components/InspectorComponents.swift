import SwiftUI

enum InspectorMetrics {
    static let compactWidth: CGFloat = 420
    static let sectionSpacing: CGFloat = 22
    static let contentPadding: CGFloat = 16
    static let groupCornerRadius: CGFloat = 14
    static let rowHeight: CGFloat = 44
}

struct InspectorScreen<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    init(
        title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InspectorMetrics.contentPadding)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                    content
                }
                .frame(maxWidth: .infinity)
                .padding(InspectorMetrics.contentPadding)
            }
            .scrollIndicators(.hidden)

            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension InspectorScreen where Actions == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, actions: { EmptyView() })
    }
}

struct InspectorFieldGroup<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: .rect(cornerRadius: InspectorMetrics.groupCornerRadius))
        .clipShape(.rect(cornerRadius: InspectorMetrics.groupCornerRadius))
    }
}

struct InspectorFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .fontWeight(.medium)
            Spacer(minLength: 12)
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: InspectorMetrics.rowHeight)
    }
}

struct InspectorGroupDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

struct InspectorSelectorOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

enum InspectorSelectorStyle {
    case joined
    case chips
}

struct InspectorSegmentedSelector<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [InspectorSelectorOption<Value>]
    var fillsWidth = false
    var style: InspectorSelectorStyle = .joined

    var body: some View {
        HStack(spacing: style == .chips ? 7 : 2) {
            ForEach(options) { option in
                Button {
                    withAnimation(.smooth(duration: 0.16)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title)
                        .font((fillsWidth ? Font.callout : Font.caption).weight(
                            selection == option.value ? .semibold : .medium
                        ))
                        .foregroundStyle(selection == option.value ? Color.white : Color.primary)
                        .lineLimit(1)
                        .padding(.horizontal, fillsWidth ? 14 : 10)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: fillsWidth ? 36 : 28)
                        .background {
                            if selection == option.value {
                                Capsule().fill(Color.accentColor)
                            } else if style == .chips {
                                Capsule().fill(.quaternary)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(style == .joined ? 3 : 0)
        .background {
            if style == .joined {
                Capsule().fill(.quaternary)
            }
        }
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
}

struct InspectorCollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct InspectorActionArea<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 6) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

struct InspectorProminentAction: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(.blue)
        .disabled(disabled)
    }
}

struct InspectorCircleMenu<Content: View>: View {
    var disabled = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .frame(width: 32, height: 32)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
        .disabled(disabled)
    }
}

struct InspectorTextAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .controlSize(.small)
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity)
    }
}

struct InspectorValueMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

struct InspectorReadOnlyValue: View {
    let value: String

    var body: some View {
        Text(value)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
}
