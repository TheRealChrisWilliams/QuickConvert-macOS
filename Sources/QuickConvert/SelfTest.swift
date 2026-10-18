import Foundation
import CoreGraphics
import ImageIO
import ConvertCore

// Headless sweep of every advertised conversion path, run by CI: QuickConvert --self-test
enum SelfTest {
    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickConvert-selftest-" + UUID().uuidString)
        let inputs = root.appendingPathComponent("in"), outputs = root.appendingPathComponent("out")
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = Converter()
        do {
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
            try makeFixtures(in: inputs)
        } catch {
            print("FIXTURES FAILED: \(error.localizedDescription)")
            return 2
        }
        let fixtures = ((try? FileManager.default.contentsOfDirectory(at: inputs, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var passed = 0, failed = 0
        for input in fixtures {
            let hasAudio = (try? worker.probe(input).hasAudio) ?? false
            let isMedia = FileFormat.kind(input) == .video
            for target in FileFormat.targets(for: [input], audioAvailable: !isMedia || hasAudio) {
                var options = ConversionOptions()
                options.destination = outputs
                let started = Date()
                do {
                    let result = try worker.convert(input, target: target.id, options: options) { _ in }
                    try validate(result.output, target: target.id, source: input, worker: worker)
                    passed += 1
                    print(String(format: "PASS %@ -> %@  %.3fs  %lld bytes", input.lastPathComponent, target.id,
                                 Date().timeIntervalSince(started), result.outputBytes))
                } catch {
                    failed += 1
                    print("FAIL \(input.lastPathComponent) -> \(target.id): \(error.localizedDescription)")
                }
            }
        }
        if let silent = fixtures.first(where: { $0.lastPathComponent.hasPrefix("silent") }) {
            var options = ConversionOptions()
            options.destination = outputs
            if (try? worker.convert(silent, target: "mp3", options: options, progress: { _ in })) != nil {
                failed += 1
                print("FAIL silent video produced an audio file")
            }
        }
        print("\(passed) passed, \(failed) failed")
        return failed == 0 && passed > 0 ? 0 : 1
    }

    private static func ffmpeg(_ args: [String]) throws {
        let process = Process()
        process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("Tools/ffmpeg")
        process.arguments = ["-nostdin", "-v", "error", "-y"] + args
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ConversionFailure.message("ffmpeg fixture failed: \(args.joined(separator: " "))") }
    }

    private static func makeFixtures(in dir: URL) throws {
        let p = { (name: String) in dir.appendingPathComponent(name).path }
        // Odd height exercises the even-dimension path.
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=641x481", "-frames:v", "1", p("image.png")])
        for ext in ["jpg", "bmp", "tif", "gif"] { try ffmpeg(["-i", p("image.png"), p("image." + ext)]) }
        try ffmpeg(["-i", p("image.png"), "-c:v", "libwebp", p("image.webp")])
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=3", p("audio.wav")])
        try ffmpeg(["-i", p("audio.wav"), "-c:a", "libmp3lame", p("audio.mp3")])
        try ffmpeg(["-i", p("audio.wav"), p("audio.flac")])
        try ffmpeg(["-i", p("audio.wav"), "-c:a", "libvorbis", p("audio.ogg")])
        try ffmpeg(["-i", p("audio.wav"), "-c:a", "aac", p("audio.m4a")])
        let av = ["-f", "lavfi", "-i", "testsrc2=size=640x361:rate=30:duration=3", "-f", "lavfi", "-i", "sine=duration=3", "-shortest"]
        try ffmpeg(av + ["-c:v", "mpeg4", "-c:a", "aac", p("video.mp4")])
        try ffmpeg(av + ["-c:v", "mpeg4", "-c:a", "aac", p("video.mov")])
        try ffmpeg(av + ["-c:v", "mpeg4", "-c:a", "libvorbis", p("video.mkv")])
        try ffmpeg(av + ["-c:v", "libvpx", "-c:a", "libvorbis", p("video.webm")])
        try ffmpeg(av + ["-c:v", "mpeg4", "-c:a", "libmp3lame", p("video.avi")])
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=2", "-c:v", "mpeg4", p("silent.mp4")])

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(dir.appendingPathComponent("document.pdf") as CFURL, mediaBox: &box, nil) else {
            throw ConversionFailure.message("PDF fixture failed")
        }
        for page in 0..<3 {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(red: 0.1, green: 0.3 + 0.2 * Double(page), blue: 0.8, alpha: 1))
            pdf.fill(CGRect(x: 72, y: 72, width: 468, height: 648))
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    private static func validate(_ output: URL, target: String, source: URL, worker: Converter) throws {
        func fail(_ why: String) -> ConversionFailure { .message("invalid output: " + why) }
        switch FileFormat.kind(URL(fileURLWithPath: "x." + target)) {
        case .pdf:
            guard CGPDFDocument(output as CFURL)?.numberOfPages == 1 else { throw fail("PDF does not have one page") }
        case .image where FileFormat.kind(source) == .pdf:
            let pages = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
            guard pages.count == 3, pages.allSatisfy(decodes) else { throw fail("expected 3 decodable pages") }
        case .image:
            guard decodes(output) || target == "gif" && FileFormat.kind(source) == .video else { throw fail("image does not decode") }
            if FileFormat.kind(source) == .video { _ = try worker.probe(output) }
        case .audio:
            let info = try worker.probe(output)
            guard info.hasAudio, info.duration > 2 else { throw fail("missing audio or short duration") }
        case .video:
            let info = try worker.probe(output)
            guard info.streams.contains(where: { $0.codec_type == "video" }), info.duration > 1.5 else { throw fail("missing video or short duration") }
            if (try? worker.probe(source).hasAudio) == true, !info.hasAudio { throw fail("audio stream dropped") }
        case .unsupported:
            throw fail("unknown target")
        }
    }

    private static func decodes(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.width > 0 && image.height > 0
    }
}
