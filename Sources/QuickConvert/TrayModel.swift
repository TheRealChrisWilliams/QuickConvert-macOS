import AppKit
import ConvertCore

struct FileOutcome: Identifiable {
    let id = UUID()
    let source: URL
    let result: Result<ConversionResult, Error>

    var output: ConversionResult? { try? result.get() }
    var wasCanceled: Bool {
        if case .failure(let error) = result { return (error as? ConversionFailure) == .cancelled }
        return false
    }
    var message: String? {
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }
}

enum Phase: Equatable {
    case idle, ready, running, canceling, finished
}

@MainActor
final class TrayModel: ObservableObject {
    @Published private(set) var staged: [URL] = []
    @Published private(set) var hovering: [URL]?
    @Published var hoverTarget: String?
    @Published var selected: String?
    @Published var options = ConversionOptions()
    @Published private(set) var silent = Set<URL>()
    @Published private(set) var probing = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var outcomes: [FileOutcome] = []
    @Published private(set) var jobFiles: [URL] = []
    @Published private(set) var jobTarget: String?
    @Published private(set) var pageCount = 0
    @Published var notice: String?

    // Tile frames in the tray's flipped coordinates; not published to avoid layout loops.
    var tileFrames: [String: CGRect] = [:]
    private var converter: Converter?
    private var probeID = UUID()

    var inputs: [URL] { hovering ?? staged }
    var kind: FileKind { inputs.first.map(FileFormat.kind) ?? .unsupported }
    var targets: [FileFormat] { FileFormat.targets(for: inputs) }
    var isBusy: Bool { phase == .running || phase == .canceling }
    var canDrop: Bool { !isBusy && !targets.isEmpty }

    func isAvailable(_ format: FileFormat) -> Bool {
        guard kind == .video, FileFormat.kind(URL(fileURLWithPath: "x." + format.id)) == .audio else { return true }
        return !probing && inputs.allSatisfy { !silent.contains($0) }
    }

    func target(at point: CGPoint) -> String? {
        targets.first { tileFrames[$0.id]?.contains(point) == true && isAvailable($0) }?.id
    }

    var rejection: String? {
        guard !inputs.isEmpty, targets.isEmpty else { return nil }
        if inputs.contains(where: { FileFormat.kind($0) == .unsupported }) {
            let names = Set(inputs.filter { FileFormat.kind($0) == .unsupported }.map { $0.pathExtension.isEmpty ? "these" : "." + $0.pathExtension.lowercased() })
            return "QuickConvert can't convert \(names.sorted().joined(separator: ", ")) files."
        }
        return "These files can't be converted together. Drop images, PDFs, audio or videos separately."
    }

    // MARK: Drag lifecycle

    func beginHover(_ urls: [URL]) {
        hovering = urls
        hoverTarget = nil
        inspect(urls)
    }

    func endHover() {
        guard hovering != nil else { return }
        hovering = nil
        hoverTarget = nil
        inspect(staged)
    }

    func commitDrop(_ urls: [URL], target: String?) {
        guard !isBusy else { return }
        stage(urls)
        if let target { start(target) }
    }

    func stage(_ urls: [URL]) {
        guard !isBusy else { return }
        hovering = nil
        hoverTarget = nil
        staged = urls
        outcomes = []
        notice = nil
        if let selected, !targets.contains(where: { $0.id == selected }) { self.selected = nil }
        phase = urls.isEmpty ? .idle : .ready
        inspect(urls)
    }

    func reset() {
        guard !isBusy else { return }
        stage([])
        selected = nil
    }

    func chooseAnotherFormat() {
        guard !isBusy else { return }
        outcomes = []
        phase = staged.isEmpty ? .idle : .ready
    }

    private func inspect(_ urls: [URL]) {
        pageCount = urls.count == 1 && FileFormat.kind(urls[0]) == .pdf ? (CGPDFDocument(urls[0] as CFURL)?.numberOfPages ?? 0) : 0
        let videos = urls.filter { FileFormat.kind($0) == .video && !silent.contains($0) }
        guard !videos.isEmpty else { probing = false; return }
        let id = UUID()
        probeID = id
        probing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let prober = Converter()
            let quiet = videos.filter { (try? prober.probe($0).hasAudio) == false }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.probeID == id else { return }
                    self.silent.formUnion(quiet)
                    self.probing = false
                }
            }
        }
    }

    // MARK: Jobs

    func start(_ target: String) {
        guard !isBusy, !staged.isEmpty else { return }
        guard let format = targets.first(where: { $0.id == target }), isAvailable(format) else {
            notice = "Choose one of the formats shown."
            return
        }
        let missing = staged.filter { !FileManager.default.isReadableFile(atPath: $0.path) }
        guard missing.isEmpty else {
            notice = "\(missing[0].lastPathComponent) is no longer available. Drop it again."
            return
        }
        let files = staged, options = self.options, worker = Converter()
        converter = worker
        selected = target
        jobFiles = files
        jobTarget = target
        outcomes = []
        notice = nil
        progress = nil
        phase = .running
        DispatchQueue.global(qos: .userInitiated).async {
            for (index, file) in files.enumerated() {
                let result = Result {
                    try worker.convert(file, target: target, options: options) { fraction in
                        // Only measurable work reports fractions below 1.
                        guard fraction < 1 || files.count > 1 else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if self.phase == .running { self.progress = (Double(index) + fraction) / Double(files.count) }
                            }
                        }
                    }
                }
                let outcome = FileOutcome(source: file, result: result)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.outcomes.append(outcome) } }
                if outcome.wasCanceled { break }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.converter = nil
                    self.progress = nil
                    self.phase = .finished
                }
            }
        }
    }

    func cancel() {
        guard phase == .running else { return }
        phase = .canceling
        converter?.cancel()
    }

    func retry() {
        guard let jobTarget else { return }
        start(jobTarget)
    }
}
