import SwiftUI

/// Renders a provider's icon from the asset catalog, falling back to an SF Symbol when no
/// asset is bundled (e.g. local providers like Ollama / LM Studio).
struct ProviderIconView: View {
    let assetName: String
    var fallbackSymbol: String = "cpu"
    var size: CGFloat = 24

    var body: some View {
        icon
            // The provider's name is always next to this, so the icon adds
            // nothing for a screen reader — and resolving an SF Symbol's
            // localized accessibility description is the hot path that pegged
            // a core once before. See the sfsymbol-a11y-locale-hang note.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        if NSImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}
