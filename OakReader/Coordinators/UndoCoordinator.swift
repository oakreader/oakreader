import Foundation
import PDFKit

class UndoCoordinator {
    weak var undoManager: UndoManager?

    init(undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    // MARK: - Page Operations

    func registerPageInsertion(page: PDFPage, at index: Int, in document: PDFDocument) {
        let pageCopy = page.copy() as? PDFPage
        undoManager?.registerUndo(withTarget: self) { coordinator in
            document.removePage(at: index)
            if let pageCopy {
                coordinator.registerPageRemoval(page: pageCopy, at: index, in: document)
            }
        }
        undoManager?.setActionName("Insert Page")
    }

    func registerPageRemoval(page: PDFPage, at index: Int, in document: PDFDocument) {
        let pageCopy = page.copy() as? PDFPage ?? page
        undoManager?.registerUndo(withTarget: self) { coordinator in
            document.insert(pageCopy, at: index)
            coordinator.registerPageInsertion(page: pageCopy, at: index, in: document)
        }
        undoManager?.setActionName("Delete Page")
    }

    func registerPageMove(from sourceIndex: Int, to destinationIndex: Int, in document: PDFDocument) {
        undoManager?.registerUndo(withTarget: self) { coordinator in
            guard let page = document.page(at: destinationIndex),
                  let pageCopy = page.copy() as? PDFPage else { return }
            document.removePage(at: destinationIndex)
            document.insert(pageCopy, at: sourceIndex)
            coordinator.registerPageMove(from: destinationIndex, to: sourceIndex, in: document)
        }
        undoManager?.setActionName("Move Page")
    }

    func registerPageRotation(at index: Int, oldRotation: Int, newRotation: Int, in document: PDFDocument) {
        undoManager?.registerUndo(withTarget: self) { coordinator in
            guard let page = document.page(at: index) else { return }
            page.rotation = oldRotation
            coordinator.registerPageRotation(at: index, oldRotation: newRotation, newRotation: oldRotation, in: document)
        }
        undoManager?.setActionName("Rotate Page")
    }

    // MARK: - Annotation Operations

    func registerAnnotationAdd(_ annotation: PDFAnnotation, on page: PDFPage) {
        undoManager?.registerUndo(withTarget: self) { coordinator in
            page.removeAnnotation(annotation)
            coordinator.registerAnnotationRemove(annotation, on: page)
        }
        undoManager?.setActionName("Add \(annotation.displayName)")
    }

    func registerAnnotationRemove(_ annotation: PDFAnnotation, on page: PDFPage) {
        undoManager?.registerUndo(withTarget: self) { coordinator in
            page.addAnnotation(annotation)
            coordinator.registerAnnotationAdd(annotation, on: page)
        }
        undoManager?.setActionName("Remove \(annotation.displayName)")
    }

    func registerAnnotationChange(_ annotation: PDFAnnotation, oldProperties: AnnotationModel, newProperties: AnnotationModel) {
        undoManager?.registerUndo(withTarget: self) { coordinator in
            oldProperties.apply(to: annotation)
            coordinator.registerAnnotationChange(annotation, oldProperties: newProperties, newProperties: oldProperties)
        }
        undoManager?.setActionName("Modify \(annotation.displayName)")
    }

    // MARK: - Group Operations

    func beginGrouping(name: String) {
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(name)
    }

    func endGrouping() {
        undoManager?.endUndoGrouping()
    }
}
