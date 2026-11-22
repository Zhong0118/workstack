import Testing
@testable import WorkbenchApp

@Test func pausedPointerDragProducesOnlyTheReleasedGap() {
    var edit = LayoutGapEdit()
    edit.dragging = true
    edit.value = 12
    #expect(edit.keyboardValue == nil)
    edit.value = 14
    #expect(edit.keyboardValue == nil)
    #expect(edit.finish() == 14)
    #expect(edit.finish() == nil)
    #expect(!edit.dragging)
}

@Test func leavingSettingsFlushesAPendingKeyboardGapOnlyOnce() {
    var edit = LayoutGapEdit()
    edit.value = 12
    edit.value = 16
    #expect(edit.keyboardValue == 16)
    #expect(edit.finish() == 16)
    #expect(edit.keyboardValue == nil)
    #expect(edit.finish() == nil)
}
