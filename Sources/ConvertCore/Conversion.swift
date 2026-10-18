import Foundation

public enum FileKind: String, Sendable {
    case image, pdf, audio, video, unsupported
}

public struct FileFormat: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let detail: String

    public static let all: [FileFormat] = [
        .init(id: "jpg", label: "JPEG", detail: "Photos"),
        .init(id: "png", label: "PNG", detail: "Lossless"),
        .init(id: "webp", label: "WebP", detail: "Web images"),
        .init(id: "pdf", label: "PDF", detail: "Document"),
        .init(id: "tif", label: "TIFF", detail: "Print images"),
        .init(id: "bmp", label: "BMP", detail: "Bitmap"),
        .init(id: "gif", label: "GIF", detail: "Image / animation"),
        .init(id: "mp4", label: "MP4", detail: "Widely supported"),
        .init(id: "mov", label: "MOV", detail: "QuickTime"),
        .init(id: "mkv", label: "MKV", detail: "Flexible video"),
        .init(id: "webm", label: "WebM", detail: "Web video"),
        .init(id: "avi", label: "AVI", detail: "Legacy video"),
        .init(id: "mp3", label: "MP3", detail: "Compact audio"),
        .init(id: "m4a", label: "M4A", detail: "AAC audio"),
        .init(id: "wav", label: "WAV", detail: "Uncompressed"),
        .init(id: "flac", label: "FLAC", detail: "Lossless audio"),
        .init(id: "ogg", label: "OGG", detail: "Vorbis audio")
    ]

    public static func normalizedExtension(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpeg": return "jpg"
        case "tiff": return "tif"
        default: return url.pathExtension.lowercased()
        }
    }

    public static func kind(_ url: URL) -> FileKind {
        switch normalizedExtension(url) {
        case "png", "jpg", "webp", "bmp", "tif", "gif": return .image
        case "pdf": return .pdf
        case "mp3", "wav", "flac", "ogg", "m4a": return .audio
        case "mp4", "mov", "mkv", "webm", "avi": return .video
        default: return .unsupported
        }
    }

    public static func targets(for urls: [URL], audioAvailable: Bool = true) -> [FileFormat] {
        guard let first = urls.first else { return [] }
        let family = kind(first)
        guard family != .unsupported, urls.allSatisfy({ kind($0) == family }) else { return [] }
        let inputs = Set(urls.map(normalizedExtension))
        return all.filter { format in
            guard !inputs.contains(format.id) else { return false }
            switch family {
            case .image: return ["png", "jpg", "webp", "bmp", "tif", "gif", "pdf"].contains(format.id)
            case .pdf: return ["png", "jpg"].contains(format.id)
            case .audio: return kind(URL(fileURLWithPath: "file." + format.id)) == .audio
            case .video:
                let targetKind = kind(URL(fileURLWithPath: "file." + format.id))
                return targetKind == .video || format.id == "gif" || (audioAvailable && targetKind == .audio)
            case .unsupported: return false
            }
        }
    }
}

public struct ConversionOptions: Sendable {
    public var quality: Double = 0.85
    public var maxDimension: Int = 0
    public var pdfDPI: Int = 144
    public var pages: String = ""
    public var audioBitrate: Int = 192
    public var videoSize: Int = 0
    public var destination: URL? = nil
    public init() {}
}

public enum ConversionFailure: LocalizedError, Equatable {
    case message(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "Conversion canceled. Your original files are safe."
        }
    }
}

public enum PageSelection {
    public static func parse(_ text: String, count: Int) throws -> [Int] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 0 else { throw ConversionFailure.message("This PDF has no readable pages.") }
        if text.isEmpty { return Array(1...count) }
        var pages = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), let start = Int(ends[0].trimmingCharacters(in: .whitespaces)) else {
                throw ConversionFailure.message("Use page numbers such as 1-3, 5, 8.")
            }
            let end = ends.count == 2 ? Int(ends[1].trimmingCharacters(in: .whitespaces)) : start
            guard let end, start >= 1, end >= start, end <= count else {
                throw ConversionFailure.message("Choose pages between 1 and \(count).")
            }
            pages.formUnion(start...end)
        }
        return pages.sorted()
    }
}

public enum OutputNaming {
    public static func available(source: URL, target: String, directory: URL? = nil, pages: Bool = false,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let parent = directory ?? source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = pages ? "_pages" : "." + target
        var number = 1
        while true {
            let tag = number == 1 ? "" : " (converted \(number))"
            let candidate = parent.appendingPathComponent(stem + tag + suffix)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }
}

public enum MediaArguments {
    public static func make(input: URL, output: URL, target: String, options: ConversionOptions, copy: Bool = false) -> [String] {
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-y", "-i", input.path]
        if copy {
            return args + ["-map", "0", "-c", "copy", output.path]
        }
        switch target {
        case "png", "jpg", "webp", "bmp", "tif", "gif":
            if target == "gif" && FileFormat.kind(input) == .video {
                args += ["-vf", "fps=12,scale=480:-2:flags=fast_bilinear", "-an", "-loop", "0"]
            } else {
                args += ["-frames:v", "1", "-an"]
                if options.maxDimension > 0 {
                    let size = options.maxDimension
                    args += ["-vf", "scale='min(\(size),iw)':'min(\(size),ih)':force_original_aspect_ratio=decrease"]
                }
                if target == "jpg" { args += ["-q:v", "2"] }
                if target == "webp" { args += ["-c:v", "libwebp", "-quality", String(Int(options.quality * 100)), "-compression_level", "0"] }
            }
        case "mp3", "wav", "flac", "ogg", "m4a":
            args += ["-map", "0:a:0", "-vn"]
            switch target {
            case "mp3": args += ["-c:a", "libmp3lame", "-b:a", "\(options.audioBitrate)k"]
            case "wav": args += ["-c:a", "pcm_s16le"]
            case "flac": args += ["-c:a", "flac", "-compression_level", "0"]
            case "ogg": args += ["-c:a", "libvorbis", "-q:a", "5"]
            default: args += ["-c:a", "aac", "-b:a", "\(options.audioBitrate)k"]
            }
        default:
            args += ["-map", "0:v:0", "-map", "0:a:0?"]
            // 4:2:0 encoders need even dimensions.
            args += ["-vf", options.videoSize > 0 ? "scale=-2:'min(\(options.videoSize),trunc(ih/2)*2)'" : "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
            switch target {
            case "webm": args += ["-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "16", "-b:v", "2M", "-c:a", "libvorbis", "-q:a", "4"]
            case "avi": args += ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame"]
            default: args += ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "6M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(options.audioBitrate)k"]
            }
        }
        return args + [output.path]
    }
}
