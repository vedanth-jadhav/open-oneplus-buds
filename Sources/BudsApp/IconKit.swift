import SwiftUI
import AppKit
import BudsCore

enum IconKit {
    static func menuBarMark() -> Image {
        if let img = NSImage(systemSymbolName: "airpods", accessibilityDescription: nil) {
            img.isTemplate = true
            return Image(nsImage: img)
        }
        return Image(systemName: "earbuds")
    }

    static func ancIcon(for mode: ANCMode?, connected: Bool) -> Image {
        let name: String? = {
            switch mode {
            case .some(.on): return "anc_on"
            case .some(.transparency): return "anc_trans"
            case .some(.off): return "anc_off"
            case .none:
                // Unknown/unsynced state: don't lie by showing "off".
                return nil
            }
        }()

        if let name, let img = loadTemplateImage(named: name) {
            return Image(nsImage: img)
        }

        // SF Symbols-first: neutral, Apple-like.
        if !connected {
            return Image(systemName: "ear.trianglebadge.exclamationmark")
        }
        switch mode {
        case .some(.on):
            return Image(systemName: "waveform.badge.minus")
        case .some(.transparency):
            return Image(systemName: "ear.and.waveform")
        case .some(.off):
            return Image(systemName: "circle")
        case .none:
            return menuBarMark()
        }
    }

    static func batteryIcon(for metric: BatteryMetric) -> Image {
        switch metric {
        case .total: return Image(systemName: "battery.100percent")
        case .left: return Image(systemName: "earbud.left")
        case .right: return Image(systemName: "earbud.right")
        case .case: return Image(systemName: "earbuds.case")
        }
    }

    enum BatteryMetric: Sendable {
        case total
        case left
        case right
        case `case`
    }

    private static func loadTemplateImage(named base: String) -> NSImage? {
        // Expect icons under Resources/Icons as anc_on.(pdf|png) etc.
        let exts = ["pdf", "png"]
        for ext in exts {
            if let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Icons"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }
}
