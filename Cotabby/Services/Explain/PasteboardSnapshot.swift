import AppKit

/// File overview:
/// An exact copy of everything on the general pasteboard (every item, every type), so a feature
/// that has to borrow the clipboard can put the user's content back afterwards. Explain &
/// Translate borrows it when it must press Edit > Copy to read a selection.
///
/// `SuggestionInserter` has the same snapshot logic as private helpers. It is duplicated here on
/// purpose rather than refactored out of that file: the inserter is a hot, upstream-maintained
/// path, and keeping this personal feature out of it keeps upstream merges conflict-free.
nonisolated struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    @MainActor
    static func capture(_ pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return representations
        }
        return PasteboardSnapshot(items: items)
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
