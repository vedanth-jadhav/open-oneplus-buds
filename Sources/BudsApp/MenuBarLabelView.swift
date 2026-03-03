import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "earbuds")
                .symbolRenderingMode(.monochrome)
                .renderingMode(.template)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if let text = model.menuBatteryText {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuAccessibilityLabel)
    }
}
