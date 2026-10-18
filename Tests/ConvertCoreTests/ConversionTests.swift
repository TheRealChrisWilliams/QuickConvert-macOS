import XCTest
@testable import ConvertCore

final class ConversionTests: XCTestCase {
    func testFormatFilteringAndSilentVideo() {
        let png = URL(fileURLWithPath: "/tmp/picture.PNG")
        XCTAssertEqual(FileFormat.targets(for: [png]).map(\.id), ["jpg", "webp", "pdf", "tif", "bmp", "gif"])
        let video = URL(fileURLWithPath: "/tmp/clip.mp4")
        XCTAssertFalse(FileFormat.targets(for: [video], audioAvailable: false).contains { $0.id == "mp3" })
        XCTAssertTrue(FileFormat.targets(for: [video], audioAvailable: true).contains { $0.id == "mp3" })
        XCTAssertTrue(FileFormat.targets(for: [png, video]).isEmpty)
    }

    func testPageRangesRejectInvalidOrUnboundedWork() throws {
        XCTAssertEqual(try PageSelection.parse("1-3, 3, 5", count: 8), [1, 2, 3, 5])
        XCTAssertEqual(try PageSelection.parse("", count: 2), [1, 2])
        for text in ["0", "4-2", "1-999999999", "1,", "-2", "1--3", "cat"] {
            XCTAssertThrowsError(try PageSelection.parse(text, count: 8), text)
        }
    }

    func testNamesNeverOverwriteExistingOutputs() {
        let source = URL(fileURLWithPath: "/tmp/holiday.v2.png")
        let used = Set(["holiday.v2.jpg", "holiday.v2 (converted 2).jpg"])
        let output = OutputNaming.available(source: source, target: "jpg", exists: { used.contains($0.lastPathComponent) })
        XCTAssertEqual(output.lastPathComponent, "holiday.v2 (converted 3).jpg")
        XCTAssertEqual(OutputNaming.available(source: source, target: "png", pages: true).lastPathComponent, "holiday.v2_pages")
    }

    func testResizeCannotTakeTheStreamCopyPath() {
        var options = ConversionOptions()
        options.videoSize = 720
        let args = MediaArguments.make(input: URL(fileURLWithPath: "/tmp/a.mp4"), output: URL(fileURLWithPath: "/tmp/b.mov"), target: "mov", options: options)
        XCTAssertTrue(args.contains("scale=-2:'min(720,trunc(ih/2)*2)'"))
        XCTAssertFalse(args.contains("copy"))
        XCTAssertTrue(args.contains("h264_videotoolbox"))
        XCTAssertEqual(args.first, "-nostdin")
    }

    func testOriginalSizeReencodeForcesEvenDimensions() {
        let args = MediaArguments.make(input: URL(fileURLWithPath: "/tmp/a.webm"), output: URL(fileURLWithPath: "/tmp/b.mp4"), target: "mp4", options: ConversionOptions())
        XCTAssertTrue(args.contains("scale=trunc(iw/2)*2:trunc(ih/2)*2"))
    }

    func testCommonTargetsForBatches() {
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.JPEG")
        XCTAssertEqual(FileFormat.targets(for: [a, b]).map(\.id), ["webp", "pdf", "tif", "bmp", "gif"])
        XCTAssertTrue(FileFormat.targets(for: [URL(fileURLWithPath: "/tmp/notes.txt")]).isEmpty)
    }
}
