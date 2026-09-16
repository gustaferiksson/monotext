import AppKit

/// Replaced by the multi-cursor implementation. Track A only ever touches this API.
final class EditorTextView: NSTextView {
    static func makeScrollView() -> NSScrollView {
        let scroll = EditorTextView.scrollablePlainDocumentContentTextView()
        (scroll.documentView as! EditorTextView).allowsUndo = true
        return scroll
    }

    var wrapsToWindow = true
}
