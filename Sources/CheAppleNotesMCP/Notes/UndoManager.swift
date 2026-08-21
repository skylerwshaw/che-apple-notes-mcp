import Foundation

/// In-memory record of write operations to enable undo/redo.
///
/// Each `Operation` stores enough info to invert itself:
/// - `create` → invert = delete by id
/// - `update` → invert = update back to old title/body
/// - `delete` → invert = create with captured title/body/folder
/// - `move`   → invert = move back to source folder
///
/// Captured fields are optional: nil means the prior state wasn't available
/// to capture (no Full Disk Access, stale/missing row), not that it was
/// empty. `Operation.isDegraded` flags this.
///
/// The stack is process-local (no persistence). Restarting the server resets
/// undo history.
final class UndoStack {

    enum Operation {
        case create(id: String)
        case update(id: String, oldTitle: String?, oldBodyHTML: String?, newTitle: String?, newBodyHTML: String?)
        case delete(id: String, title: String?, bodyHTML: String?, folder: String?, account: String?)
        case move(id: String, fromFolder: String?, account: String?, toFolder: String)

        /// True when the state this entry needs to invert itself wasn't
        /// available to capture (no Full Disk Access, or a stale/missing
        /// SQLite row) — undo still attempts a best-effort inversion, but
        /// this makes the gap visible instead of silently wrong. `create`
        /// captures nothing, so it's never degraded.
        var isDegraded: Bool {
            switch self {
            case .create: return false
            case .update(_, let oldTitle, _, _, _): return oldTitle == nil
            case .delete(_, let title, _, _, _): return title == nil
            case .move(_, let fromFolder, _, _): return fromFolder == nil
            }
        }

        var humanDescription: String {
            let suffix = isDegraded ? " (prior state unavailable)" : ""
            switch self {
            case .create(let id): return "created note \(id)"
            case .update(let id, _, _, _, _): return "updated note \(id)" + suffix
            case .delete(let id, _, _, _, _): return "deleted note \(id)" + suffix
            case .move(let id, _, _, let to): return "moved note \(id) to \(to)" + suffix
            }
        }
    }

    private var undoStack: [Operation] = []
    private var redoStack: [Operation] = []
    private let maxDepth: Int

    init(maxDepth: Int = 50) {
        self.maxDepth = maxDepth
    }

    func record(_ op: Operation) {
        undoStack.append(op)
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
        redoStack.removeAll()
    }

    func popForUndo() -> Operation? {
        guard let op = undoStack.popLast() else { return nil }
        redoStack.append(op)
        return op
    }

    func popForRedo() -> Operation? {
        guard let op = redoStack.popLast() else { return nil }
        undoStack.append(op)
        return op
    }

    /// Non-destructive look at the next redo entry, so a caller can decide
    /// to refuse it without popping — a refusal after popping silently
    /// migrates the entry back onto the undo stack
    /// ([#24](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/24)).
    func peekForRedo() -> Operation? {
        redoStack.last
    }

    /// Rewrites the top of the redo stack in place. `popForUndo` pushes an
    /// entry there unconditionally, but a case that mints new state while
    /// undoing (undo-of-delete recreates under a new id) can go stale before
    /// redo ever sees it ([#24](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/24)).
    func replaceTopOfRedo(_ op: Operation) {
        guard !redoStack.isEmpty else { return }
        redoStack[redoStack.count - 1] = op
    }

    func history() -> [String] {
        undoStack.enumerated().map { "\($0): \($1.humanDescription)" }
    }

    func undoDepth() -> Int { undoStack.count }
    func redoDepth() -> Int { redoStack.count }
}
