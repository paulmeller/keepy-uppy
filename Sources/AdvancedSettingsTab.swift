import SwiftUI

/// The tab Tasks 5, 9 and 10 fill — the CLI on your `PATH`, hot keys, and
/// diagnostics. It ships before any of them because each of the three needs it
/// to exist, and a tab created three times is a tab with three different
/// section orders.
///
/// Until then it says so, in the shape the Triggers pane's own empty state
/// already uses: a symbol and a sentence, centred, rather than a blank pane
/// that reads as a view which failed to draw. The sentence itself lives in
/// `Sources/SessionDisplay.swift` with the rest of the user-facing copy, and is
/// tested there.
struct AdvancedSettingsTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(advancedSettingsPlaceholder)
                .settingsFootnote()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
