import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ConvertCore

struct ConversionResult: Sendable {
    let source: URL
    let output: URL
    let inputBytes: Int64
    let outputBytes: Int64
    let preservedStreams: Bool
}

struct MediaInfo: Decodable, Sendable {
    struct Stream: Decodable, Sendable { let codec_type: String }
    struct Format: Decodable, Sendable { let duration: String? }
    let streams: [Stream]
    let format: Format?
    var hasAudio: Bool { streams.contains { $0.codec_type == "audio" } }
    var duration: Double { Double(format?.duration ?? "") ?? 0 }
}

final class ProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var pending = ""
    let duration: Double
    let progress: @Sendable (Double) -> Void

    init(duration: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.progress = progress
    }

    func append(_ data: Data, error: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if error {
            errors.append(data)
            if errors.count > 16_384 { errors.removeFirst(errors.count - 16_384) }
        } else {
            output.append(data)
            if output.count > 65_536 { output.removeFirst(output.count - 65_536) }
            pending += String(decoding: data, as: UTF8.self)
            while let end = pending.firstIndex(of: "\n") {
                let line = String(pending[..<end])
                pending.removeSubrange(...end)
                if line.hasPrefix("out_time_us="), duration > 0,
                   let micros = Double(line.dropFirst("out_time_us=".count)) {
                    progress(min(0.99, max(0, micros / 1_000_000 / duration)))
                }
            }
        }
        lock.unlock()
    }

    func snapshot() -> (Data, String) {
        lock.lock()
        defer { lock.unlock() }
        return (output, String(decoding: errors, as: UTF8.self))
    }
}

final class Converter: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var canceled = false

    func cancel() {
        lock.lock()
        canceled = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
        let pid = running.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if running.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func checkCancellation() throws {
        lock.lock()
        let value = canceled
        lock.unlock()
        if value { throw ConversionFailure.cancelled }
    }

    private func tool(_ name: String) throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw ConversionFailure.message("QuickConvert's conversion tools are missing. Reinstall the app from its DMG.")
        }
        let path = resources.appendingPathComponent("Tools").appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: path.path) else {
            throw ConversionFailure.message("QuickConvert's conversion tools are missing. Reinstall the app from its DMG.")
        }
        return path
    }

    private func run(_ toolName: String, _ arguments: [String], duration: Double = 0,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> (Int32, Data, String) {
        try checkCancellation()
        let task = Process()
        task.executableURL = try tool(toolName)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        let capture = ProcessCapture(duration: duration, progress: progress)
        output.fileHandleForReading.readabilityHandler = { capture.append($0.availableData, error: false) }
        errors.fileHandleForReading.readabilityHandler = { capture.append($0.availableData, error: true) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            process = nil
            lock.unlock()
        }
        // waitUntilExit spins the run loop, which busy-waits on worker threads.
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        lock.lock()
        process = task
        lock.unlock()
        do { try task.run() }
        catch { throw ConversionFailure.message("The conversion tool couldn't start. Reinstall QuickConvert and try again.") }
        do { try checkCancellation() }
        catch { if task.isRunning { task.terminate() } }
        exited.wait()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        capture.append(output.fileHandleForReading.readDataToEndOfFile(), error: false)
        capture.append(errors.fileHandleForReading.readDataToEndOfFile(), error: true)
        try checkCancellation()
        let (data, details) = capture.snapshot()
        return (task.terminationStatus, data, details)
    }

    func probe(_ url: URL) throws -> MediaInfo {
        let (status, data, _) = try run("ffprobe", ["-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", url.path])
        guard status == 0, let info = try? JSONDecoder().decode(MediaInfo.self, from: data) else {
            throw ConversionFailure.message("This media file couldn't be read. Try another file or choose another format.")
        }
        return info
    }

    static func bytes(_ url: URL) -> Int64 {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(0) { $0 + bytes($1) }
        }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func convert(_ input: URL, target: String, options: ConversionOptions,
                 progress: @escaping @Sendable (Double) -> Void) throws -> ConversionResult {
        try checkCancellation()
        guard FileFormat.targets(for: [input]).contains(where: { $0.id == target }) else {
            throw ConversionFailure.message("This file can't be converted to the selected format.")
        }
        guard FileManager.default.isReadableFile(atPath: input.path) else {
            throw ConversionFailure.message("This file couldn't be read. Check its permissions or choose another file.")
        }
        let parent = options.destination ?? input.deletingLastPathComponent()
        let work = parent.appendingPathComponent(".QuickConvert-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false) }
        catch { throw ConversionFailure.message("Can't save in this folder. Choose another destination and try again.") }
        defer { try? FileManager.default.removeItem(at: work) }
        let isPDF = FileFormat.kind(input) == .pdf
        let temporary = work.appendingPathComponent(isPDF ? "pages" : "output." + target)
        var preserved = false
        if isPDF {
            try renderPDF(input, output: temporary, target: target, options: options, progress: progress)
        } else if FileFormat.kind(input) == .image && target != "webp" {
            let image = try readImage(input, work: work, limit: options.maxDimension)
            try checkCancellation()
            if target == "pdf" { try imagePDF(image, output: temporary) }
            else { try writeImage(image, output: temporary, target: target, quality: options.quality) }
        } else {
            let sourceKind = FileFormat.kind(input)
            let destinationKind = FileFormat.kind(temporary)
            let info = sourceKind == .video || sourceKind == .audio ? try probe(input) : nil
            if destinationKind == .audio, info?.hasAudio != true {
                throw ConversionFailure.message("This video has no audio to extract. Choose a video format instead.")
            }
            if sourceKind == .video, destinationKind == .video, options.videoSize == 0 {
                let args = MediaArguments.make(input: input, output: temporary, target: target, options: options, copy: true)
                let (status, _, _) = try run("ffmpeg", args, duration: info?.duration ?? 0, progress: progress)
                preserved = status == 0
                if !preserved { try? FileManager.default.removeItem(at: temporary) }
            }
            if !preserved {
                let args = MediaArguments.make(input: input, output: temporary, target: target, options: options)
                let (status, _, details) = try run("ffmpeg", args, duration: info?.duration ?? 0, progress: progress)
                guard status == 0 else {
                    throw ConversionFailure.message("This file couldn't be converted. Try another format.\n\n" + String(details.suffix(1_200)))
                }
            }
            if destinationKind == .audio || destinationKind == .video { _ = try probe(temporary) }
        }
        try checkCancellation()
        guard Self.bytes(temporary) > 0 else { throw ConversionFailure.message("The conversion produced an empty file. Try another format.") }
        var final = OutputNaming.available(source: input, target: target, directory: parent, pages: isPDF)
        while true {
            do { try FileManager.default.moveItem(at: temporary, to: final); break }
            catch {
                if FileManager.default.fileExists(atPath: final.path) {
                    final = OutputNaming.available(source: input, target: target, directory: parent, pages: isPDF)
                } else { throw ConversionFailure.message("The converted file couldn't be saved. Choose another folder and retry.") }
            }
        }
        progress(1)
        return ConversionResult(source: input, output: final, inputBytes: Self.bytes(input), outputBytes: Self.bytes(final), preservedStreams: preserved)
    }

    private func readImage(_ input: URL, work: URL, limit: Int) throws -> CGImage {
        var source = CGImageSourceCreateWithURL(input as CFURL, nil)
        if source == nil {
            let decoded = work.appendingPathComponent("decoded.png")
            let (status, _, _) = try run("ffmpeg", ["-nostdin", "-v", "error", "-i", input.path, "-frames:v", "1", decoded.path])
            if status == 0 { source = CGImageSourceCreateWithURL(decoded as CFURL, nil) }
        }
        guard let source else { throw ConversionFailure.message("This image couldn't be opened. It may be damaged or unsupported.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let size = limit > 0 ? limit : max(width, height)
        guard size > 0, limit > 0 || Double(width) * Double(height) < 100_000_000 else {
            throw ConversionFailure.message("This image is too large to open at full size. Set a smaller longest edge in Options.")
        }
        let settings: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, settings as CFDictionary) else {
            throw ConversionFailure.message("This image couldn't be decoded. Try another file.")
        }
        return image
    }

    private func writeImage(_ image: CGImage, output: URL, target: String, quality: Double) throws {
        let types = ["jpg": UTType.jpeg, "png": .png, "tif": .tiff, "bmp": .bmp, "gif": .gif]
        guard let type = types[target], let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionFailure.message("This image format couldn't be written. Try PNG or JPEG instead.")
        }
        var final = image
        if target == "jpg" {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let context = bitmap(width: image.width, height: image.height) else {
                throw ConversionFailure.message("There isn't enough memory to flatten this image. Set a smaller longest edge in Options.")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else {
                throw ConversionFailure.message("This image couldn't be prepared for JPEG. Try PNG instead.")
            }
            final = flattened
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: 1]
        CGImageDestinationAddImage(destination, final, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure.message("The image couldn't be saved. Choose another folder and retry.") }
    }

    private func bitmap(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func imagePDF(_ image: CGImage, output: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(output as CFURL, mediaBox: &bounds, nil) else {
            throw ConversionFailure.message("The PDF couldn't be created. Choose another folder and retry.")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: bounds)
        context.endPDFPage()
        context.closePDF()
    }

    private func renderPDF(_ input: URL, output: URL, target: String, options: ConversionOptions,
                           progress: @escaping @Sendable (Double) -> Void) throws {
        guard let document = CGPDFDocument(input as CFURL),
              !document.isEncrypted || document.isUnlocked || document.unlockWithPassword("") else {
            throw ConversionFailure.message("This PDF is locked or unreadable. Save an unlocked copy and try again.")
        }
        let pages = try PageSelection.parse(options.pages, count: document.numberOfPages)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let scale = Double(options.pdfDPI) / 72
        for (index, number) in pages.enumerated() {
            try checkCancellation()
            guard let page = document.page(at: number) else { throw ConversionFailure.message("Page \(number) couldn't be read.") }
            let box = page.getBoxRect(.mediaBox)
            let rotated = abs(page.rotationAngle) % 180 == 90
            let width = Int(ceil((rotated ? box.height : box.width) * scale))
            let height = Int(ceil((rotated ? box.width : box.height) * scale))
            guard width > 0, height > 0, Double(width) * Double(height) < 100_000_000,
                  let context = bitmap(width: width, height: height) else {
                throw ConversionFailure.message("Page \(number) is too large at this resolution. Choose a lower PDF resolution.")
            }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw ConversionFailure.message("Page \(number) couldn't be rendered.") }
            let name = String(format: "page-%03d.%@", number, target)
            try writeImage(image, output: output.appendingPathComponent(name), target: target, quality: options.quality)
            progress(Double(index + 1) / Double(pages.count))
        }
    }
}
