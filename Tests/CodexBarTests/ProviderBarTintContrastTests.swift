import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct ProviderBarTintContrastTests {
    /// Ollama ships #888888, the same neutral gray as the usage bar track, so a 100% left bar
    /// looked empty. Its bars must use the label color instead of the brand gray.
    @Test
    func `ollama usage bars use the label color instead of the track gray`() {
        let ollama = ProviderDescriptorRegistry.descriptor(for: .ollama).branding.color

        #expect(ProviderAccentPalette.usesLabelBarTint(ollama))
        #expect(UsageMenuCardView.Model.progressColor(for: .ollama) == Color(nsColor: .labelColor))
        #expect(UsageMenuCardView.Model.inlineDashboardBarColor(for: .ollama) == Color(nsColor: .labelColor))
    }

    @Test
    func `achromatic accents use the label tint`() {
        #expect(ProviderAccentPalette.usesLabelBarTint(ProviderColor(hex: 0x888888)))
        #expect(ProviderAccentPalette.usesLabelBarTint(ProviderColor(hex: 0x8E8E93)))
        #expect(ProviderAccentPalette.usesLabelBarTint(ProviderColor(hex: 0x6B7280)))
        #expect(ProviderAccentPalette.usesLabelBarTint(ProviderColor(hex: 0x000000)))
        #expect(ProviderAccentPalette.usesLabelBarTint(ProviderColor(hex: 0xFFFFFF)))
    }

    /// Chromatic brands keep their own color, so the fix only touches bars that were unreadable.
    @Test
    func `chromatic brand colors keep their own bar tint`() {
        let chromatic: [UsageProvider] = [.codex, .claude, .cursor, .opencodego, .antigravity, .minimax, .ibmbob]
        for provider in chromatic {
            let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
            #expect(
                !ProviderAccentPalette.usesLabelBarTint(color),
                "\(provider.rawValue) brand color should stay chromatic")
            #expect(
                UsageMenuCardView.Model.progressColor(for: provider)
                    == Color(red: color.red, green: color.green, blue: color.blue),
                "\(provider.rawValue) bar should keep its brand color")
        }
    }
}
