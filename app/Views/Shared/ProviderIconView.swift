import SwiftUI

/// Renders a provider's icon from the asset catalog, falling back to an SF Symbol when no
/// asset is bundled (e.g. local providers like Ollama / LM Studio).
struct ProviderIconView: View {
    let assetName: String
    var fallbackSymbol: String = "cpu"
    var size: CGFloat = 24

    var body: some View {
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
