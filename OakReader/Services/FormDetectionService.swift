import Foundation
import PDFKit
import Vision
import AppKit

struct FormDetectionService {

    func detectFormFields(on page: PDFPage) async -> [FormFieldModel] {
        guard let pageIndex = page.document?.index(for: page) else { return [] }
        guard let cgImage = page.renderToCGImage(dpi: PDFDefaults.ocrDPI) else { return [] }

        let pageRect = page.bounds(for: .mediaBox)

        // Run rectangle detection and text recognition in parallel
        async let detectedRects = detectRectangles(in: cgImage, pageRect: pageRect)
        async let detectedLabels = detectTextLabels(in: cgImage, pageRect: pageRect)

        let rects = await detectedRects
        let labels = await detectedLabels

        var formFields: [FormFieldModel] = []

        for rect in rects {
            let fieldType = classifyField(rect: rect, labels: labels, pageRect: pageRect)
            var field = FormFieldModel(fieldType: fieldType, bounds: rect.bounds, pageIndex: pageIndex)

            // Try to find a label for this field
            if let label = findNearestLabel(for: rect.bounds, in: labels) {
                field.name = sanitizeFieldName(label)
                field.tooltip = label
            }

            formFields.append(field)
        }

        return formFields
    }

    // MARK: - Rectangle Detection

    private struct DetectedRect {
        let bounds: CGRect
        let aspectRatio: CGFloat
    }

    private func detectRectangles(
        in cgImage: CGImage,
        pageRect: CGRect
    ) async -> [DetectedRect] {
        await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard let observations = request.results as? [VNRectangleObservation], error == nil else {
                    continuation.resume(returning: [])
                    return
                }

                let rects: [DetectedRect] = observations.compactMap { observation in
                    let bbox = observation.boundingBox
                    let pdfRect = CGRect(
                        x: bbox.origin.x * pageRect.width + pageRect.origin.x,
                        y: bbox.origin.y * pageRect.height + pageRect.origin.y,
                        width: bbox.width * pageRect.width,
                        height: bbox.height * pageRect.height
                    )

                    // Filter out very small or very large rectangles
                    guard pdfRect.width > 10 && pdfRect.height > 5 else { return nil }
                    guard pdfRect.width < pageRect.width * 0.95 else { return nil }
                    guard pdfRect.height < pageRect.height * 0.5 else { return nil }

                    let aspect = pdfRect.width / pdfRect.height
                    return DetectedRect(bounds: pdfRect, aspectRatio: aspect)
                }

                continuation.resume(returning: rects)
            }

            request.minimumAspectRatio = 0.1
            request.maximumAspectRatio = 30.0
            request.minimumSize = 0.01
            request.maximumObservations = 50
            request.minimumConfidence = 0.5

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Text Label Detection

    private struct DetectedLabel {
        let text: String
        let bounds: CGRect
    }

    private func detectTextLabels(
        in cgImage: CGImage,
        pageRect: CGRect
    ) async -> [DetectedLabel] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                    continuation.resume(returning: [])
                    return
                }

                let labels: [DetectedLabel] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let bbox = observation.boundingBox
                    let pdfRect = CGRect(
                        x: bbox.origin.x * pageRect.width + pageRect.origin.x,
                        y: bbox.origin.y * pageRect.height + pageRect.origin.y,
                        width: bbox.width * pageRect.width,
                        height: bbox.height * pageRect.height
                    )
                    return DetectedLabel(text: candidate.string, bounds: pdfRect)
                }

                continuation.resume(returning: labels)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Classification Heuristics

    private func classifyField(
        rect: DetectedRect,
        labels: [DetectedLabel],
        pageRect: CGRect
    ) -> FormFieldType {
        // Small, roughly square rectangles are likely checkboxes
        if rect.bounds.width < 25 && rect.bounds.height < 25 && rect.aspectRatio > 0.7 && rect.aspectRatio < 1.4 {
            return .checkbox
        }

        // Narrow, tall and small might be radio button areas
        if rect.bounds.width < 20 && rect.bounds.height < 20 {
            return .radioButton
        }

        // Wide, short rectangles are text fields
        if rect.aspectRatio > 3.0 && rect.bounds.height < 30 {
            return .textField
        }

        // Check if nearby text suggests a dropdown
        let nearbyLabels = labels.filter { label in
            let distance = abs(label.bounds.midY - rect.bounds.midY)
            return distance < rect.bounds.height * 2
        }
        for label in nearbyLabels {
            let lower = label.text.lowercased()
            if lower.contains("select") || lower.contains("choose") || lower.contains("dropdown") {
                return .dropdown
            }
            if lower.contains("sign") {
                return .signature
            }
        }

        // Default to text field for medium-sized rectangles
        if rect.aspectRatio > 1.5 {
            return .textField
        }

        return .textField
    }

    private func findNearestLabel(
        for fieldBounds: CGRect,
        in labels: [DetectedLabel]
    ) -> String? {
        var bestLabel: DetectedLabel?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for label in labels {
            // Labels are typically to the left or above the field
            let labelRight = label.bounds.maxX
            let labelBottom = label.bounds.minY

            let isToLeft = labelRight <= fieldBounds.minX + 5 && abs(label.bounds.midY - fieldBounds.midY) < fieldBounds.height * 2
            let isAbove = labelBottom >= fieldBounds.maxY - 5 && abs(label.bounds.midX - fieldBounds.midX) < fieldBounds.width

            if isToLeft || isAbove {
                let dx = label.bounds.midX - fieldBounds.midX
                let dy = label.bounds.midY - fieldBounds.midY
                let distance = sqrt(dx * dx + dy * dy)

                if distance < bestDistance {
                    bestDistance = distance
                    bestLabel = label
                }
            }
        }

        // Only use label if it's reasonably close
        if bestDistance < 200, let label = bestLabel {
            return label.text
        }

        return nil
    }

    private func sanitizeFieldName(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = cleaned.components(separatedBy: .whitespaces)
        return components.joined(separator: "_").prefix(40).lowercased()
    }
}
