import Foundation
import Testing
import TransferCore
@testable import TransferUI

@MainActor
struct SelectionTests {
    let a = SavedConnection(name: "A", host: "a")

    func connected(_ count: Int) async -> TransferModel {
        let model = TransferModel(provider: FakeProvider([FakeSession(a, folders: files(count, in: "/home"))]))
        await model.connect(a)
        return model
    }

    /// UIM2-02: reading the selection costs one pass per folder, not one per selected item.
    @Test func readingALargeSelectionIsLinear() async {
        let model = await connected(3_000)
        model.snapshot.selection = Set(model.displayedItems.map(\.path))
        model.setViewMode(.columns)
        model.selectInColumns([RemoteItem(path: RemotePath(string: "/home"), kind: .directory)], parent: RemotePath(string: "/"))
        model.snapshot.selection = Set(model.items.map(\.path)).union([RemotePath(string: "/home")])
        let start = ContinuousClock.now
        let selected = model.selectedItems
        _ = model.starTitle(model.starTargets)
        _ = model.primaryItem
        let took = start.duration(to: .now)
        #expect(selected.count == 3_000)
        #expect(took < .milliseconds(300), "took \(took)")
    }

    /// UIM2-07: in list and icon view the selection keeps only what is shown, as Finder's does, so
    /// Copy or a drag never takes an item the filter hid.
    @Test func theFilterNarrowsTheSelectionToWhatIsShown() async {
        let model = await connected(30)
        model.setViewMode(.list)
        model.snapshot.selection = Set(model.displayedItems.map(\.path))
        model.filter = "file-1"
        #expect(model.displayedItems.count == 11)
        #expect(model.snapshot.selection == Set(model.displayedItems.map(\.path)))
        #expect(model.selectedItems.map(\.path) == model.displayedItems.map(\.path))
        #expect(model.primaryItem == model.displayedItems.first)
    }

    /// In column view a selected folder is the location itself, found in its parent's listing.
    @Test func aFolderSelectedInColumnsIsItsParentsItem() async {
        let session = FakeSession(a, folders: files(3, in: "/home").merging([RemotePath(string: "/"): [RemoteItem(path: RemotePath(string: "/home"), kind: .directory)]]) { $1 })
        let model = TransferModel(provider: FakeProvider([session]))
        await model.connect(a)
        model.setViewMode(.columns)
        await model.navigate(RemotePath(string: "/"))
        model.selectInColumns([RemoteItem(path: RemotePath(string: "/home"), kind: .directory)], parent: RemotePath(string: "/"))
        #expect(model.snapshot.path == RemotePath(string: "/home"))
        #expect(model.selectedItems.map(\.path) == [RemotePath(string: "/home")])
        #expect(model.primaryItem?.kind == .directory)
    }
}
