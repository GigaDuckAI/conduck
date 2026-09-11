// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentGalleryPageTests.swift
//
// Pins the pure parts of the model-free full-screen gallery:
//
//   1. `AttachmentGalleryPage.pages(forImageAttachments:)` — Chat's mapping.
//      Page order and the 1-based numbering are what the accessibility label
//      and the loader's id lookup both depend on.
//   2. `AttachmentGalleryResidency.residentIndices` — the window that decides
//      which pages may hold a full-size bitmap. The clamped ends and the
//      radius-0 (memory-warning) case are the load-bearing ones.
//   3. `Image.decodedStrictlyBounded` — must return NIL for bytes that are not
//      an image instead of falling back to an unbounded platform decode, and
//      the bound it delegates to must actually cap the long edge.
//   4. `AttachmentGalleryShareItem` — what Chat's Share control actually hands
//      the system: a CONCRETE encoding (an abstract `public.image` claim is one
//      no recipient can consume), the page's own bytes unaltered, a filename
//      the destination can write, and no read at all until the person shares.
//
// Privacy: synthetic bytes only; the "real image" is generated in-process.

import XCTest
import SwiftUI
import CoreGraphics
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers
@testable import Conduck

@MainActor
final class AttachmentGalleryPageTests: XCTestCase {

    // MARK: - Page mapping

    private func makeImageAttachment(sequence: Int, thumbnail: Data?) -> AttachmentRecord {
        AttachmentRecord(
            id: UUID(),
            mimeType: "image/jpeg",
            filename: "shot-\(sequence)",
            thumbnailData: thumbnail,
            extractedText: nil,
            width: 100,
            height: 80,
            byteSize: 1234,
            sequence: sequence,
            createdAt: Date(),
            isServerReference: false,
            storedKey: nil,
            previewKind: nil
        )
    }

    func testPagesCarryEveryAttachmentIdAndThumbnailInOrder() {
        let attachments = [
            makeImageAttachment(sequence: 0, thumbnail: Data([0x01])),
            makeImageAttachment(sequence: 1, thumbnail: nil),
            makeImageAttachment(sequence: 2, thumbnail: Data([0x03]))
        ]

        let pages = AttachmentGalleryPage.pages(forImageAttachments: attachments)

        XCTAssertEqual(pages.map(\.id), attachments.map(\.id), "page order must follow the attachments")
        XCTAssertEqual(pages.map(\.thumbnailData), attachments.map(\.thumbnailData),
                       "a thumbnail-less attachment still becomes a page (it loads its full bytes)")
    }

    func testPagesAreNumberedOneBasedInTheAccessibilityLabel() {
        let attachments = (0..<2).map { makeImageAttachment(sequence: $0, thumbnail: nil) }

        let pages = AttachmentGalleryPage.pages(forImageAttachments: attachments)

        XCTAssertEqual(pages.first?.accessibilityLabel, "Image 1 of 2")
        XCTAssertEqual(pages.last?.accessibilityLabel, "Image 2 of 2")
    }

    func testAnEmptyAttachmentListMapsToNoPages() {
        XCTAssertTrue(AttachmentGalleryPage.pages(forImageAttachments: []).isEmpty)
    }

    // MARK: - What the header calls a page

    /// The title is the name the person's own source carried. A photo-library
    /// pick, a camera shot and a pasted bitmap frequently have none, and the
    /// header says NOTHING rather than falling back to the accessibility label
    /// — which is already the position, and would be printed a second time
    /// beside the header's own counter.
    func testAPagesTitleIsItsFilenameAndNeverTheCounterAgain() {
        let named = AttachmentRecord(
            id: UUID(), mimeType: "image/jpeg", filename: "kitchen.jpg",
            thumbnailData: nil, extractedText: nil, width: 10, height: 10, byteSize: 1,
            sequence: 0, createdAt: Date(), isServerReference: false,
            storedKey: nil, previewKind: nil
        )
        let unnamed = AttachmentRecord(
            id: UUID(), mimeType: "image/jpeg", filename: nil,
            thumbnailData: nil, extractedText: nil, width: 10, height: 10, byteSize: 1,
            sequence: 1, createdAt: Date(), isServerReference: false,
            storedKey: nil, previewKind: nil
        )
        let blank = AttachmentRecord(
            id: UUID(), mimeType: "image/jpeg", filename: "   ",
            thumbnailData: nil, extractedText: nil, width: 10, height: 10, byteSize: 1,
            sequence: 2, createdAt: Date(), isServerReference: false,
            storedKey: nil, previewKind: nil
        )

        let pages = AttachmentGalleryPage.pages(forImageAttachments: [named, unnamed, blank])

        XCTAssertEqual(pages[0].title, "kitchen.jpg")
        XCTAssertNil(pages[1].title, "a picture with no name is not given the counter as one")
        XCTAssertNil(pages[2].title, "and a name of nothing but spaces is no name")
        XCTAssertEqual(pages[1].accessibilityLabel, "Image 2 of 3",
                       "the spoken label still places the page in the collection")
    }

    /// The share sheet needs a name even where the header shows none — a blank
    /// preview row reads as broken — so THAT is where the accessibility label
    /// stands in.
    func testAnUnnamedPageStillHasSomethingToCallItselfInAShare() {
        let pages = (0..<2).map { index in
            AttachmentGalleryPage(
                id: UUID(),
                thumbnailData: nil,
                accessibilityLabel: "Image \(index + 1) of 2",
                title: index == 0 ? "kitchen.jpg" : nil
            )
        }

        XCTAssertEqual(AttachmentGalleryHeader.shareName(for: pages[0].id, in: pages), "kitchen.jpg")
        XCTAssertEqual(AttachmentGalleryHeader.shareName(for: pages[1].id, in: pages), "Image 2 of 2")
        XCTAssertEqual(AttachmentGalleryHeader.shareName(for: UUID(), in: pages), "")
    }

    func testATitleOfNothingIsNoTitle() {
        XCTAssertNil(AttachmentGalleryHeader.displayTitle(nil))
        XCTAssertNil(AttachmentGalleryHeader.displayTitle(""))
        XCTAssertNil(AttachmentGalleryHeader.displayTitle(" \n\t "))
        XCTAssertEqual(AttachmentGalleryHeader.displayTitle("  Kitchen sketch  "), "Kitchen sketch")
    }

    /// The counter explains a collection, so it appears only where there is one
    /// to explain, and it counts from one.
    func testTheCounterAppearsOnlyForAGalleryThatCanBePaged() {
        XCTAssertNil(AttachmentGalleryHeader.counter(index: 0, count: 1),
                     "one page is not a collection")
        XCTAssertNil(AttachmentGalleryHeader.counter(index: 0, count: 0))
        XCTAssertEqual(AttachmentGalleryHeader.counter(index: 0, count: 10), "1 of 10")
        XCTAssertEqual(AttachmentGalleryHeader.counter(index: 2, count: 10), "3 of 10")
        // Clamped for the same reason the cursor is: the pages can change under
        // a value that was valid when the pager wrote it.
        XCTAssertEqual(AttachmentGalleryHeader.counter(index: 99, count: 10), "10 of 10")
        XCTAssertEqual(AttachmentGalleryHeader.counter(index: -4, count: 10), "1 of 10")
    }

    // MARK: - What a shared page claims to be

    /// The defect this pins: `public.image` is ABSTRACT. An item registered
    /// only under it fails `canLoadObject(NSImage.self)`, throws when a
    /// destination asks for a real encoding, and reaches Files as an
    /// extensionless name. Chat's stored image bytes are always JPEG
    /// (`ImageProcessor.encodeJPEG`), so the concrete claim is also the true
    /// one.
    func testASharedPageAdvertisesARealImageEncodingAndNotTheAbstractOne() {
        let exported = AttachmentGalleryShareItem.exportedContentTypes()

        XCTAssertTrue(exported.contains(.jpeg), "a destination asking for a picture must find one")
        XCTAssertFalse(
            exported.contains(.image),
            "public.image is what nothing declares itself readable as"
        )
        for type in exported {
            XCTAssertFalse(type.isDynamic, "an invented type identifier describes nothing")
        }
    }

    /// The bytes are read once, at export, and are handed over unaltered — the
    /// share must be the picture the page is showing, not a re-encoding of it.
    func testSharingExportsTheSameBytesThePageLoads() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        let item = AttachmentGalleryShareItem(
            name: "kitchen.jpg",
            filename: "kitchen.jpg",
            load: { bytes }
        )

        let exported = try await item.exported(as: .jpeg)

        XCTAssertEqual(exported, bytes)
        XCTAssertEqual(
            item.suggestedFilename,
            "kitchen.jpg",
            "the name has to reach the transfer itself, not just the picker's row"
        )
    }

    /// Nothing is read until the person actually shares: building the item must
    /// not touch the store, or opening a gallery of twenty pictures would read
    /// twenty payloads to draw one button.
    func testBuildingTheShareItemReadsNothing() {
        let reads = LoadCounter()
        _ = AttachmentGalleryShareItem(
            name: "kitchen.jpg",
            filename: "kitchen.jpg",
            load: { reads.increment(); return Data() }
        )
        XCTAssertEqual(reads.count, 0)
    }

    /// The file the destination writes. A title is not a filename, and the
    /// extension has to describe the BYTES rather than whatever the source was
    /// called.
    func testTheSharedCopyIsNamedForTheBytesItActuallyCarries() {
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(fromTitle: "kitchen.jpg"),
            "kitchen.jpg",
            "a name that already states JPEG is left alone"
        )
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(fromTitle: "kitchen.JPEG"),
            "kitchen.JPEG",
            "and the same holds however it is spelled"
        )
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(fromTitle: "photo.heic"),
            "photo.jpg",
            "a dual-route image keeps its SOURCE name while the stored bytes are the normalised JPEG"
        )
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(fromTitle: "Meeting v1.2"),
            "Meeting v1.2.jpg",
            "a trailing fragment that names no type is part of the name"
        )
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(fromTitle: "Image 2 of 2"),
            "Image 2 of 2.jpg",
            "the unnamed page's stand-in still lands as a file"
        )
    }

    /// A filename the file system would refuse, or none at all, still has to
    /// produce something a destination can write.
    func testAnUnnameableTitleStillProducesAFilename() {
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(fromTitle: "holiday/2024:notes"),
            "holiday-2024-notes.jpg",
            "separators become dashes rather than being dropped, so two titles stay distinct"
        )
        XCTAssertEqual(AttachmentGalleryShareItem.suggestedFilename(fromTitle: ""), "Image.jpg")
        XCTAssertEqual(AttachmentGalleryShareItem.suggestedFilename(fromTitle: "   "), "Image.jpg")
        XCTAssertEqual(AttachmentGalleryShareItem.suggestedFilename(fromTitle: ".."), "Image.jpg")
    }

    /// The picker row and the written file are derived from the same name, so a
    /// person who recognised the row recognises the file.
    func testTheFilenameFollowsTheSameNameTheShareRowShows() {
        let pages = (0..<2).map { index in
            AttachmentGalleryPage(
                id: UUID(),
                thumbnailData: nil,
                accessibilityLabel: "Image \(index + 1) of 2",
                title: index == 0 ? "kitchen" : nil
            )
        }

        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(for: pages[0].id, in: pages),
            "kitchen.jpg"
        )
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(for: pages[1].id, in: pages),
            "Image 2 of 2.jpg"
        )
        XCTAssertEqual(
            AttachmentGalleryShareItem.suggestedFilename(for: UUID(), in: pages),
            "Image.jpg",
            "a page that is no longer there is still named something writable"
        )
    }

    // MARK: - Residency window

    func testTheWindowKeepsTheCurrentPageAndBothNeighbours() {
        let resident = AttachmentGalleryResidency.residentIndices(current: 3, count: 8, radius: 1)
        XCTAssertEqual(resident, [2, 3, 4])
    }

    func testTheWindowClampsAtBothEnds() {
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: 0, count: 5, radius: 1),
            [0, 1],
            "there is no page -1 to keep resident"
        )
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: 4, count: 5, radius: 1),
            [3, 4]
        )
    }

    /// The memory-warning shape: neighbours are released, the page the user is
    /// looking at is not.
    func testRadiusZeroKeepsOnlyTheCurrentPage() {
        XCTAssertEqual(AttachmentGalleryResidency.residentIndices(current: 2, count: 6, radius: 0), [2])
    }

    func testAnOutOfRangeCurrentIndexStillLeavesAPageResident() {
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: 99, count: 3, radius: 1),
            [1, 2],
            "a stale start index must clamp, never leave the gallery with nothing to render"
        )
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: -4, count: 3, radius: 0),
            [0]
        )
    }

    func testAnEmptyGalleryHasNoResidentPages() {
        XCTAssertTrue(AttachmentGalleryResidency.residentIndices(current: 0, count: 0, radius: 1).isEmpty)
    }

    func testAWindowWiderThanTheGalleryKeepsEveryPage() {
        XCTAssertEqual(AttachmentGalleryResidency.residentIndices(current: 1, count: 3, radius: 9), [0, 1, 2])
    }

    // MARK: - Strict bounded decode

    /// A solid-colour JPEG of the requested pixel size, built through ImageIO so
    /// the test never ships an image asset.
    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())

        let buffer = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    func testStrictDecodeReturnsNilForBytesThatAreNotAnImage() async {
        let notAnImage = Data("this is a note, not a picture".utf8)
        let image = await Image.decodedStrictlyBounded(from: notAnImage, maxPixel: 4096)
        XCTAssertNil(image, "the strict path must report failure, never fall back to a platform decode")
    }

    func testStrictDecodeReturnsNilForEmptyBytes() async {
        let image = await Image.decodedStrictlyBounded(from: Data(), maxPixel: 4096)
        XCTAssertNil(image)
    }

    func testStrictDecodeAcceptsRealImageBytes() async throws {
        let jpeg = try makeJPEG(width: 300, height: 200)
        let image = await Image.decodedStrictlyBounded(from: jpeg, maxPixel: 4096)
        XCTAssertNotNil(image)
    }

    /// The bound itself, measured on the CGImage the strict decoder returns
    /// wrapped — `displayCGImage` is the whole of its decode.
    func testTheBoundCapsTheLongEdgeOfARealImage() throws {
        let jpeg = try makeJPEG(width: 512, height: 256)

        let bounded = try XCTUnwrap(ImageProcessor.displayCGImage(from: jpeg, maxPixel: 128))
        XCTAssertEqual(bounded.width, 128, "the long edge is the bound")
        XCTAssertEqual(bounded.height, 64, "the aspect ratio survives the bound")

        let unbounded = try XCTUnwrap(ImageProcessor.displayCGImage(from: jpeg, maxPixel: nil))
        XCTAssertEqual(unbounded.width, 512)
        XCTAssertEqual(unbounded.height, 256)
    }

    func testTheBoundedPrimitiveAlsoRefusesNonImageBytes() {
        XCTAssertNil(ImageProcessor.displayCGImage(from: Data("nope".utf8), maxPixel: 128))
    }

    // MARK: - The container each platform can actually draw

    /// SOURCE-SHAPE GUARD: `.tabViewStyle(.page)` does not exist on native
    /// macOS, so a `TabView` there falls back to the default tab-bar style and
    /// — since no page sets a `.tabItem` — draws one UNLABELED segment per
    /// page: a segmented control floating over the sheet, which is what the
    /// "page dots" in a Mac screenshot of this gallery actually were.
    ///
    /// It has to be a source check because the defect is a rendered container
    /// on one platform, which no XCTest process can see. What it holds is the
    /// split itself: the pager stays inside the iOS branch, and the Mac draws
    /// the current page directly with navigation of its own.
    func testTheMacDrawsOnePageDirectlyAndTheTabPagerStaysOnIOS() throws {
        let path = "Conduck/Views/Conversation/AttachmentFullScreenView.swift"
        let source = try RefusalLaneSource.source(at: path)

        XCTAssertEqual(
            source.components(separatedBy: "TabView(").count - 1,
            1,
            "one pager, in one branch — a second TabView is a fork of the gallery"
        )

        let afterPager = try XCTUnwrap(source.range(of: "var pager"))
        let tail = String(source[afterPager.upperBound...])
        let split = try XCTUnwrap(
            tail.range(of: "#else"),
            "the pager must BRANCH; a single container cannot serve both platforms"
        )
        let iosBranch = String(tail[..<split.lowerBound])
        let macBranch = String(tail[split.upperBound...])

        XCTAssertTrue(
            iosBranch.contains("#if os(iOS)") && iosBranch.contains("TabView("),
            "the swipeable pager is the iOS half"
        )
        XCTAssertTrue(
            iosBranch.contains("indexDisplayMode: .never"),
            "the header's counter says which page this is, so the dots would repeat it"
        )
        XCTAssertTrue(
            macBranch.contains("macPage"),
            "the Mac half renders the current page rather than a tab bar"
        )
        XCTAssertTrue(
            source.contains(".id(page.id)"),
            """
            The Mac page must be identified BY PAGE: zoom, pan, the decoded \
            original and a failed page's Retry are all state of the page view, \
            so without this Next arrives magnified on the previous picture's \
            failure.
            """
        )
        XCTAssertTrue(
            source.contains("keyboardShortcut(shortcut, modifiers: [])"),
            """
            Arrow keys reach the gallery through a shortcut on the navigation \
            control, not a key handler on the container: a sheet gives no \
            control initial focus, so a focus-dependent handler does nothing \
            until the person clicks first.
            """
        )
    }

    /// Both containers write ONE cursor, which is what keeps the header, the
    /// actions slot and the drawn picture describing the same page. A Mac
    /// container that tracked its own index would be indistinguishable on the
    /// opening page and wrong after the first click of Next.
    func testBothContainersDriveTheSameCursor() throws {
        let source = try RefusalLaneSource.source(
            at: "Conduck/Views/Conversation/AttachmentFullScreenView.swift"
        )
        XCTAssertTrue(source.contains("selection.index = target"), "Next/Previous write the cursor")
        XCTAssertTrue(source.contains("pagerSelection"), "and so does the iOS pager")
        XCTAssertFalse(
            source.contains("@State private var macIndex"),
            "a second index is the drift this component exists to prevent"
        )
    }

    // MARK: - Memory pressure, on both platforms

    /// SOURCE-SHAPE GUARD: the residency window shrinks under memory pressure on
    /// EVERY platform the gallery runs on.
    ///
    /// It has to be a source check because neither signal can be raised from a
    /// test: iOS's is a system notification and the Mac's is a dispatch
    /// memory-pressure source, and the arithmetic they drive
    /// (`residentIndices(radius: 0)`) is already pinned above. What no
    /// behavioural test can hold is that both lanes EXIST — an iOS gallery
    /// without one keeps two extra 4096 px bitmaps decoded at exactly the
    /// moment the system is asking for memory back, and nothing fails.
    ///
    /// The Mac's lane is the narrower one: its container mounts the current
    /// page alone, so the window is already at its floor and the signal changes
    /// nothing today. It is held here anyway, because the rule belongs to the
    /// window rather than to the container — a Mac container that ever
    /// pre-mounts a neighbour must inherit the release, not rediscover it.
    func testBothPlatformsShrinkTheResidencyWindowUnderMemoryPressure() throws {
        let path = "Conduck/Views/Conversation/AttachmentFullScreenView.swift"
        let source = try RefusalLaneSource.source(at: path)

        XCTAssertTrue(
            source.contains("UIApplication.didReceiveMemoryWarningNotification"),
            "iOS shrinks the window on the system memory warning"
        )
        XCTAssertTrue(
            source.contains("DispatchSource.makeMemoryPressureSource"),
            """
            macOS posts no memory warning, so its equivalent signal is a dispatch \
            memory-pressure source. Without one the Mac gallery holds its \
            neighbours' originals through the pressure.
            """
        )
        XCTAssertEqual(
            source.components(separatedBy: "residencyRadius = 0").count - 1,
            2,
            "one release lane per platform, and both drop the radius to the current page alone"
        )
    }
}


/// A counter a `@Sendable` loader closure can bump, so "nothing was read" is a
/// measurement rather than an assumption.
private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
