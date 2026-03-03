import SwiftUI

struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    shape
                        .fill(.background)
                        .overlay { shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
                }
        } else {
            content
                .glassEffect(.regular, in: shape)
        }
    }
}

struct GlassCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(14)
            .modifier(GlassSurface(shape: shape))
    }
}

struct StatusChip: View {
    let text: String
    let kind: Kind

    enum Kind {
        case idle
        case running
        case success
        case failure
    }

    var color: Color {
        switch kind {
        case .idle: return .secondary
        case .running: return .blue
        case .success: return .green
        case .failure: return .red
        }
    }

    var body: some View {
        Text(text)
            .font(Typography.chip)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .foregroundStyle(color)
            .background {
                Capsule(style: .continuous)
                    .modifier(GlassSurface(shape: Capsule(style: .continuous)))
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(color.opacity(0.14))
                    }
            }
    }
}
