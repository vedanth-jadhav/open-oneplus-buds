import SwiftUI
import BudsCore

struct NoiseControlButtonsView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    let selection: ANCMode?
    let enabled: Bool
    let setMode: (ANCMode) -> Void

    @State private var optimisticSelection: ANCMode?
    @State private var optimisticClearTask: Task<Void, Never>?

    var body: some View {
        let effectiveSelection = optimisticSelection ?? selection
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                modeButton(mode: .on, systemImage: "waveform.badge.minus", help: "Noise Cancellation", selection: effectiveSelection)
                modeButton(mode: .transparency, systemImage: "ear.and.waveform", help: "Transparency", selection: effectiveSelection)
                modeButton(mode: .off, systemImage: "circle", help: "Off", selection: effectiveSelection)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: selection) { _, _ in
            // Device-originated updates (or successful set) should always win.
            optimisticClearTask?.cancel()
            optimisticClearTask = nil
            optimisticSelection = nil
        }
        .onDisappear {
            optimisticClearTask?.cancel()
            optimisticClearTask = nil
        }
    }

    @ViewBuilder
    private func modeButton(mode: ANCMode, systemImage: String, help: String, selection: ANCMode?) -> some View {
        let isSelected = (selection == mode)

        Button {
            guard enabled else { return }
            if self.selection != mode {
                optimisticSelection = mode
                optimisticClearTask?.cancel()
                optimisticClearTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if optimisticSelection == mode {
                        optimisticSelection = nil
                    }
                }
                setMode(mode)
            }
        } label: {
            Image(systemName: systemImage)
                .symbolRenderingMode(isSelected ? .monochrome : .hierarchical)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 52, height: 52)
                .background {
                    Circle()
                        .modifier(GlassSurface(shape: Circle()))
                        .overlay {
                            if isSelected {
                                Circle()
                                    .fill(.tint.opacity(reduceTransparency ? 0.25 : 0.55))
                            } else {
                                Circle()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
                            }
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(reduceTransparency ? 0.10 : 0.18), lineWidth: 1)
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressFeedbackButtonStyle())
        .help(help)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct GlassPressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}
