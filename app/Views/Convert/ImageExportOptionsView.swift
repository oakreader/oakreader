import SwiftUI

struct ImageExportOptionsView: View {
    @Binding var dpi: Int
    @Binding var imageFormat: ExportSheet.ImageFormat
    @Binding var jpegQuality: CGFloat

    private let dpiOptions = [72, 150, 225, 300, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // DPI
            VStack(alignment: .leading, spacing: 4) {
                Text("Resolution (DPI)")
                    .font(.caption)
                    .fontWeight(.medium)

                Picker("DPI:", selection: $dpi) {
                    ForEach(dpiOptions, id: \.self) { value in
                        Text("\(value) DPI").tag(value)
                    }
                }
                .pickerStyle(.segmented)

                Text(dpiDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Image format
            VStack(alignment: .leading, spacing: 4) {
                Text("Image Format")
                    .font(.caption)
                    .fontWeight(.medium)

                Picker("Format:", selection: $imageFormat) {
                    ForEach(ExportSheet.ImageFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }

            // JPEG quality (only for JPEG)
            if imageFormat == .jpeg {
                VStack(alignment: .leading, spacing: 4) {
                    Text("JPEG Quality: \(Int(jpegQuality * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)

                    Slider(value: $jpegQuality, in: 0.1...1.0, step: 0.05)

                    HStack {
                        Text("Smaller file")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Better quality")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Estimated size
            HStack {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Higher DPI produces larger files but better quality.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dpiDescription: String {
        switch dpi {
        case 72: return "Screen quality - smallest files"
        case 150: return "Good quality for most uses"
        case 225: return "High quality"
        case 300: return "Print quality"
        case 600: return "Very high quality - large files"
        default: return ""
        }
    }
}
