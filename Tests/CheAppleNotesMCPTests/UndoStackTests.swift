import Testing
@testable import CheAppleNotesMCP

@Suite struct UndoStackTests {

    @Test func recordPushesOntoUndoStack() {
        let stack = UndoStack()
        stack.record(.create(id: "abc"))
        #expect(stack.undoDepth() == 1)
        #expect(stack.redoDepth() == 0)
    }

    @Test func popForUndoMovesEntryToRedoStack() {
        let stack = UndoStack()
        stack.record(.create(id: "abc"))

        let op = stack.popForUndo()

        #expect(op != nil)
        #expect(stack.undoDepth() == 0)
        #expect(stack.redoDepth() == 1)
    }

    @Test func popForRedoMovesEntryBack() {
        let stack = UndoStack()
        stack.record(.create(id: "abc"))
        _ = stack.popForUndo()

        let op = stack.popForRedo()

        #expect(op != nil)
        #expect(stack.undoDepth() == 1)
        #expect(stack.redoDepth() == 0)
    }

    @Test func popForUndoOnEmptyReturnsNil() {
        let stack = UndoStack()
        #expect(stack.popForUndo() == nil)
    }

    @Test func popForRedoOnEmptyReturnsNil() {
        let stack = UndoStack()
        #expect(stack.popForRedo() == nil)
    }

    @Test func newRecordClearsRedoStack() {
        let stack = UndoStack()
        stack.record(.create(id: "a"))
        _ = stack.popForUndo()
        #expect(stack.redoDepth() == 1)

        stack.record(.create(id: "b"))

        #expect(stack.redoDepth() == 0)
        #expect(stack.undoDepth() == 1)
    }

    @Test func overflowDropsOldestEntries() {
        let stack = UndoStack(maxDepth: 3)
        stack.record(.create(id: "a"))
        stack.record(.create(id: "b"))
        stack.record(.create(id: "c"))
        stack.record(.create(id: "d"))

        #expect(stack.undoDepth() == 3)

        let history = stack.history()
        #expect(history.count == 3)
        #expect(!history.contains(where: { $0.contains("created note a") }))
        #expect(history.contains(where: { $0.contains("created note d") }))
    }

    @Test func historyRendersEachOperationOnce() {
        let stack = UndoStack()
        stack.record(.create(id: "x"))
        stack.record(.delete(id: "y", title: "t", bodyHTML: "b", folder: "f", account: "a"))
        stack.record(.move(id: "z", fromFolder: "src", account: nil, toFolder: "dst"))

        let history = stack.history()

        #expect(history.count == 3)
        #expect(history[0].contains("created note x"))
        #expect(history[1].contains("deleted note y"))
        #expect(history[2].contains("moved note z to dst"))
    }

    // MARK: - Peek / replace ([#24](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/24))

    @Test func peekForRedoDoesNotMutateEitherStack() {
        let stack = UndoStack()
        stack.record(.create(id: "a"))
        _ = stack.popForUndo()

        let peeked = stack.peekForRedo()

        #expect(peeked != nil)
        #expect(stack.undoDepth() == 0)
        #expect(stack.redoDepth() == 1)
    }

    @Test func peekForRedoOnEmptyReturnsNil() {
        let stack = UndoStack()
        #expect(stack.peekForRedo() == nil)
    }

    @Test func replaceTopOfRedoOverwritesTheEntryPopForUndoPushed() {
        // Mirrors undo-of-delete: popForUndo pushes the stale-id entry, the
        // caller mints a new id, and rewrites it before redo ever sees it.
        let stack = UndoStack()
        stack.record(.delete(id: "stale", title: "t", bodyHTML: "b", folder: "f", account: "a"))
        _ = stack.popForUndo()

        stack.replaceTopOfRedo(.delete(id: "minted", title: "t", bodyHTML: "b", folder: "f", account: "a"))

        guard case .delete(let id, _, _, _, _) = stack.peekForRedo() else {
            Issue.record("expected .delete on top of redo stack")
            return
        }
        #expect(id == "minted")
        #expect(stack.redoDepth() == 1)
    }

    @Test func replaceTopOfRedoOnEmptyStackIsANoop() {
        let stack = UndoStack()
        stack.replaceTopOfRedo(.create(id: "x"))
        #expect(stack.redoDepth() == 0)
    }

    // MARK: - Degraded capture

    @Test func deleteWithNilTitleIsDegraded() {
        let op = UndoStack.Operation.delete(id: "a", title: nil, bodyHTML: nil, folder: nil, account: nil)
        #expect(op.isDegraded)
        #expect(op.humanDescription.contains("(prior state unavailable)"))
    }

    @Test func deleteWithCapturedTitleIsNotDegraded() {
        let op = UndoStack.Operation.delete(id: "a", title: "t", bodyHTML: "b", folder: "f", account: "acc")
        #expect(!op.isDegraded)
        #expect(!op.humanDescription.contains("(prior state unavailable)"))
    }

    @Test func moveWithNilFromFolderIsDegraded() {
        let op = UndoStack.Operation.move(id: "a", fromFolder: nil, account: nil, toFolder: "dst")
        #expect(op.isDegraded)
        #expect(op.humanDescription.contains("(prior state unavailable)"))
    }

    @Test func updateWithNilOldTitleIsDegraded() {
        let op = UndoStack.Operation.update(id: "a", oldTitle: nil, oldBodyHTML: nil, newTitle: "n", newBodyHTML: nil)
        #expect(op.isDegraded)
        #expect(op.humanDescription.contains("(prior state unavailable)"))
    }
}
