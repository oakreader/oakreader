import Foundation
import PDFKit

struct FormFieldModel: Identifiable, Equatable {
    let id: UUID
    var fieldType: FormFieldType
    var name: String
    var bounds: CGRect
    var pageIndex: Int
    var defaultValue: String
    var options: [String]  // for dropdowns
    var isRequired: Bool
    var isReadOnly: Bool
    var maxLength: Int?
    var fontSize: CGFloat
    var fontName: String
    var tooltip: String
    var groupName: String?  // for radio button groups

    init(fieldType: FormFieldType, bounds: CGRect, pageIndex: Int) {
        self.id = UUID()
        self.fieldType = fieldType
        self.name = "\(fieldType.label)_\(UUID().uuidString.prefix(6))"
        self.bounds = bounds
        self.pageIndex = pageIndex
        self.defaultValue = ""
        self.options = []
        self.isRequired = false
        self.isReadOnly = false
        self.maxLength = nil
        self.fontSize = PDFDefaults.defaultFontSize
        self.fontName = PDFDefaults.defaultFontName
        self.tooltip = ""
        self.groupName = nil
    }

    func createAnnotation() -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
        switch fieldType {
        case .textField:
            annotation.widgetFieldType = .text
            annotation.widgetStringValue = defaultValue
            if let maxLength {
                annotation.setValue(maxLength, forAnnotationKey: PDFAnnotationKey(rawValue: "/MaxLen"))
            }
        case .checkbox:
            annotation.widgetFieldType = .button
            annotation.setValue("/Ch", forAnnotationKey: PDFAnnotationKey(rawValue: "/FT"))
            annotation.buttonWidgetState = defaultValue == "true" ? .onState : .offState
        case .radioButton:
            annotation.widgetFieldType = .button
            annotation.buttonWidgetState = defaultValue == "true" ? .onState : .offState
        case .dropdown:
            annotation.widgetFieldType = .choice
            annotation.choices = options
            annotation.widgetStringValue = defaultValue
        case .pushButton:
            annotation.widgetFieldType = .button
            annotation.caption = defaultValue.isEmpty ? "Button" : defaultValue
        case .signature:
            annotation.widgetFieldType = .signature
        }
        annotation.fieldName = name
        if let font = NSFont(name: fontName, size: fontSize) {
            annotation.font = font
        }
        return annotation
    }
}
