import SwiftUI
import BudsCore
import AppKit

struct PopoverRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                HeaderCardView()
                ANCCardView()
                BatteryCardView()
                FooterView()
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            model.onPopoverOpen()
        }
        .onDisappear {
            model.onPopoverClose()
        }
    }
}

private struct HeaderCardView: View {
    @EnvironmentObject var model: AppModel

    var statusText: String {
        switch model.connection {
        case .idle: return "Idle"
        case .bluetoothOff: return "Bluetooth Off"
        case .bluetoothUnauthorized: return "Bluetooth Permission Needed"
        case .bluetoothUnsupported: return "Bluetooth Unsupported"
        case .bluetoothResetting: return "Bluetooth Resetting"
        case .scanning: return "Looking for Buds…"
        case .connecting(let name): return name.map { "Connecting · \($0)" } ?? "Connecting…"
        case .discovering: return "Discovering"
        case .authenticating: return "Authenticating"
        case .connected(let name): return name.map { "Connected · \($0)" } ?? "Connected"
        case .reconnecting: return "Reconnecting"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var ancLabel: String {
        guard let anc = model.anc else { return "Noise Control" }
        switch anc {
        case .on: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .off: return "Off"
        }
    }

    var batterySummary: String {
        guard let total = model.displayBattery?.totalWeightedPercent else { return "--" }
        return "\(total)%"
    }

    var body: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: iconName)
                    .renderingMode(.template)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 20, weight: .semibold))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Buds")
                        .font(Typography.title)
                    Text(statusText)
                        .font(Typography.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(ancLabel)
                        .font(Typography.subtitle.weight(.semibold))
                        .lineLimit(1)
                    Label {
                        Text(batterySummary)
                            .font(Typography.subtitle.weight(.semibold))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "battery.100percent")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                }
            }

            if shouldShowNotConnected {
                StatusChip(text: notConnectedText, kind: .failure)
                    .padding(.top, 10)
            }

            if needsBluetoothHelp {
                HStack {
                    Spacer()
                    Button("Open Bluetooth Privacy") { openBluetoothPrivacy() }
                        .buttonStyle(.glass)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isConnected: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private var iconName: String {
        isConnected ? "earbuds" : "ear.trianglebadge.exclamationmark"
    }

    private var shouldShowNotConnected: Bool {
        !isConnected && model.lastError != nil
    }

    private var notConnectedText: String {
        if let err = model.lastError, !err.isEmpty { return err }
        return "Not connected"
    }

    private var needsBluetoothHelp: Bool {
        switch model.connection {
        case .bluetoothUnauthorized, .bluetoothOff:
            return true
        default:
            return false
        }
    }

    private func openBluetoothPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ANCCardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Noise Control")
                        .font(Typography.sectionHeader)
                    Spacer()
                    Text(selectionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                NoiseControlButtonsView(
                    selection: model.anc,
                    enabled: isConnected,
                    setMode: { model.setANC($0) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isConnected: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private var selectionLabel: String {
        guard let anc = model.anc else { return "—" }
        switch anc {
        case .on: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .off: return "Off"
        }
    }
}

private struct BatteryCardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Battery")
                        .font(Typography.sectionHeader)
                    Spacer()
                    Button {
                        model.refreshBattery()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                HStack(spacing: 10) {
                    MetricPill(metric: .total, title: "Total", value: model.displayBattery?.totalWeightedPercent.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                    MetricPill(metric: .left, title: "L", value: model.battery?.left.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                    MetricPill(metric: .right, title: "R", value: model.battery?.right.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                    MetricPill(metric: .case, title: "Case", value: model.displayBattery?.case.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                }

                if let ts = model.battery?.lastUpdated {
                    Text("Updated \(ts.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FooterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Button {
                model.reconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.glassProminent)
            Spacer()
            Button("Quit") { model.quit() }
                .buttonStyle(.glass)
        }
    }
}

private struct MetricPill: View {
    let metric: IconKit.BatteryMetric
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            IconKit.batteryIcon(for: metric)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 20, height: 20)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Typography.metricValue)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
    }
}
