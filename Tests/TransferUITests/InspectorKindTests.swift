import AppKit
import ImageIO
import SwiftUI
import Testing
import TransferCore
import UniformTypeIdentifiers
@testable import TransferUI

/// What the inspector shows by kind of file: a file of a type the Mac does not know shows as text
/// when its head is text and as its icon otherwise; any other type goes to Quick Look, whose
/// installed extensions may draw it, but only the types it draws without one are fetched ahead;
/// a picture is drawn at the size of the preview area.
extension InspectorTests {
    /// A folder of local files standing in for the server's, and a model showing it with the
    /// inspector open in a hosted column 320 points wide.
    func showing(_ files: [String: Data]) async throws -> (model: TransferModel, session: FakeSession, window: NSWindow, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TransferUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copies: [RemotePath: URL] = [:]
        var items: [RemoteItem] = []
        for (name, bytes) in files {
            let url = folder.appending(path: name)
            try bytes.write(to: url)
            copies[path(name)] = url
            items.append(RemoteItem(path: path(name), kind: .file, size: UInt64(bytes.count)))
        }
        let session = FakeSession(server, folders: [home: items])
        session.liveExtensions.value = ["txt"]
        session.inspectorCopies.value = copies
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        let window = await window(InspectorColumn(model: model).frame(width: 320, height: 640), width: 320)
        await model.connect(server)
        _ = await eventually { model.items.count == items.count }
        return (model, session, window, folder)
    }

    func select(_ name: String, in model: TransferModel) {
        model.snapshot.selection = [path(name)]
        model.selectionChanged()
    }

    /// A file whose type the Mac does not know, or that has no extension, and whose head is UTF-8
    /// text shows as text. It still opens for viewing, not Live: the contents never decide that.
    @Test func aFileOfUnknownTypeWhoseHeadIsTextShowsAsText() async throws {
        let source = "const std = @import(\"std\");\npub fn main() void {}\n"
        let (model, session, window, folder) = try await showing([
            "build.xqz": Data(source.utf8), "README": Data("Read me: café\n".utf8),
        ])
        defer { window.close(); try? FileManager.default.removeItem(at: folder) }

        select("build.xqz", in: model)
        #expect(await eventually { model.inspectorPreview == .text(source) })
        select("README", in: model)
        #expect(await eventually { model.inspectorPreview == .text("Read me: café\n") })
        #expect(await session.openKind(fileName: "build.xqz") == .view)
        #expect(EditableFile.openKind(fileName: "build.xqz", extensions: TransferConfig.builtIn.extensionSet) == .view)
    }

    /// The same files holding a NUL or bytes that are not UTF-8 show their icon, once their head
    /// has been read.
    @Test func aFileOfUnknownTypeThatIsNotTextShowsItsIcon() async throws {
        let (model, session, window, folder) = try await showing([
            "blob.xqz": Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x00, 0x00]), "latin.xqz": Data([0x63, 0x61, 0x66, 0xE9, 0x0A]),
            "a.txt": Data("a\n".utf8),
        ])
        defer { window.close(); try? FileManager.default.removeItem(at: folder) }

        for name in ["blob.xqz", "latin.xqz"] {
            // From a text preview, so the change to the icon is seen.
            select("a.txt", in: model)
            #expect(await eventually { model.inspectorPreview == .text("a\n") })
            select(name, in: model)
            #expect(await eventually { session.calls.value.contains("inspector /home/\(name)") })
            #expect(await eventually { model.inspectorPreview == nil && model.inspectorWait == .icon }, "\(name)")
        }
    }

    /// A type outside Quick Look's own list (an archive) is fetched for the selection and handed to
    /// Quick Look, which draws it with whatever extension the Mac has for it.
    @Test func aTypeQuickLookDrawsOnlyThroughAnExtensionGoesToQuickLook() async throws {
        let (model, _, window, folder) = try await showing(["bundle.zip": Data("PK\u{3}\u{4}".utf8)])
        defer { window.close(); try? FileManager.default.removeItem(at: folder) }

        select("bundle.zip", in: model)
        #expect(await eventually { model.inspectorPreview == .file(folder.appending(path: "bundle.zip")) })
    }

    /// Arrowing past such a file never pulls it down: once a preview lands, its neighbors are
    /// fetched ahead only when Quick Look draws their type without an extension.
    @Test func thePrefetchSkipsATypeOutsideQuickLooksList() async throws {
        let (model, session, window, folder) = try await showing([
            "a.pdf": Data("%PDF-1.4\n".utf8), "b.txt": Data("b\n".utf8), "c.zip": Data("PK\u{3}\u{4}".utf8),
        ])
        defer { window.close(); try? FileManager.default.removeItem(at: folder) }
        #expect(model.displayedItems.map(\.name) == ["a.pdf", "b.txt", "c.zip"])

        select("b.txt", in: model)
        #expect(await eventually { model.inspectorPreview == .text("b\n") })
        // c.zip comes first (the next row), then a.pdf: once a.pdf is fetched, c.zip was passed over.
        #expect(await eventually { session.calls.value.contains("inspector /home/a.pdf") })
        #expect(!session.calls.value.contains("inspector /home/c.zip"))
    }

    /// A picture is drawn at the size of the area it shows in, not decoded whole: a large one
    /// comes back no larger than the area at the screen's scale.
    @Test func aPictureIsDrawnAtTheSizeOfTheArea() async throws {
        let context = try #require(CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let (model, _, window, folder) = try await showing(["wide.png": data as Data])
        defer { window.close(); try? FileManager.default.removeItem(at: folder) }

        select("wide.png", in: model)
        #expect(await eventually(seconds: 10) { if case .picture? = model.inspectorPreview { true } else { false } })
        guard case .picture(let picture)? = model.inspectorPreview else { return }
        let box = model.inspectorPictureBox
        // The column is 320 wide, less 16 a side, less the picture's 8-point margin.
        #expect(abs(box.size.width - (320 - 32 - 16)) < 0.5, "\(box)")
        #expect(picture.width <= Int((box.size.width * box.scale).rounded(.up)))
        #expect(picture.width >= Int(box.size.width) / 2)
        #expect(picture.width == picture.height * 2)
    }
}
