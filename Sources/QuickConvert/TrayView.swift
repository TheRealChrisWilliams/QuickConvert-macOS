import AppKit
import SwiftUI
import ConvertCore

struct TileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TrayActions {
    var chooseFiles: () -> Void
    var chooseFolder: (_ thenRetry: Bool) -> Void
    var dismiss: () -> Void
    var resized: (CGFloat) -> Void
}

struct TrayView: View {
    @ObservedObject var model: TrayModel
    let actions: TrayActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOptions = false

    static let width: CGFloat = 348

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        .onPreferenceChange(HeightKey.self) { actions.resized($0) }
        .onPreferenceChange(TileFramesKey.self) { model.tileFrames = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "tray")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: model.hoverTarget)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .running, .canceling: RunningView(model: model)
        case .finished: ResultView(model: model, actions: actions)
        case .idle, .ready:
            if model.inputs.isEmpty { emptyState } else { chooser }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Drop files here")
                .font(.headline)
            Text("Images, PDFs, audio and video")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: actions.chooseFiles)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.tertiary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop files here to convert them")
    }

    @ViewBuilder private var chooser: some View {
        SourceRow(files: model.inputs)
        if let rejection = model.rejection {
            Label(rejection, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.hovering == nil { Button("Choose Files…", action: actions.chooseFiles) }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(model.targets) { format in
                    FormatTile(format: format,
                               available: model.isAvailable(format),
                               reason: model.probing ? "Checking…" : "No audio",
                               highlighted: model.hoverTarget == format.id,
                               selected: model.hovering == nil && model.selected == format.id) {
                        model.selected = format.id
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TileFramesKey.self, value: [format.id: proxy.frame(in: .named("tray"))])
                    })
                }
            }
            if model.hovering != nil {
                Text(model.hoverTarget == nil ? "Release on a format to convert, or here to choose options." : "Release to convert. Your original stays as it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                DisclosureGroup("Options", isExpanded: $showOptions) {
                    OptionsView(model: model, chooseFolder: { actions.chooseFolder(false) })
                        .padding(.top, 6)
                }
                .font(.callout)
                HStack {
                    Button("Clear") { model.reset() }
                    Spacer()
                    Button(convertTitle) { if let id = model.selected { model.start(id) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selected == nil)
                }
            }
        }
    }

    private var convertTitle: String {
        guard let id = model.selected, let format = FileFormat.all.first(where: { $0.id == id }) else { return "Convert" }
        return "Convert to \(format.label)"
    }
}

struct SourceRow: View {
    let files: [URL]

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: files[0].path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + Converter.bytes($1) }, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct FormatTile: View {
    let format: FileFormat
    let available: Bool
    let reason: String
    let highlighted: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(format.label).font(.system(.body, weight: .semibold))
                Text(available ? format.detail : reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlighted || selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(highlighted || selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if selected || highlighted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
        .accessibilityLabel("Convert to \(format.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct OptionsView: View {
    @ObservedObject var model: TrayModel
    let chooseFolder: () -> Void

    private var target: String? { model.selected }
    private var targetKind: FileKind { target.map { FileFormat.kind(URL(fileURLWithPath: "x." + $0)) } ?? .unsupported }

    var body: some View {
        Form {
            switch model.kind {
            case .image:
                if target == "jpg" || target == "webp" {
                    Picker("Quality", selection: $model.options.quality) {
                        Text("Smaller").tag(0.7)
                        Text("Balanced").tag(0.85)
                        Text("Best").tag(0.95)
                    }
                }
                Picker("Size", selection: $model.options.maxDimension) {
                    Text("Original").tag(0)
                    Text("3840 px").tag(3840)
                    Text("2048 px").tag(2048)
                    Text("1024 px").tag(1024)
                }
                if target == "jpg" { note("Transparent areas become white.") }
                if model.inputs.contains(where: { ["gif", "webp"].contains(FileFormat.normalizedExtension($0)) }) {
                    note("Animated images convert their first frame.")
                }
            case .pdf:
                TextField("Pages", text: $model.options.pages, prompt: Text(model.pageCount > 0 ? "All \(model.pageCount)" : "All"))
                Picker("Resolution", selection: $model.options.pdfDPI) {
                    Text("Screen").tag(144)
                    Text("High").tag(216)
                    Text("Print").tag(300)
                }
                note("Each page is saved as an image in a new folder.")
            case .audio:
                if target == "mp3" || target == "m4a" { bitrate }
            case .video:
                if targetKind == .video {
                    Picker("Size", selection: $model.options.videoSize) {
                        Text("Original").tag(0)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    }
                    note(model.options.videoSize == 0 ? "Streams are copied without re-encoding when the format allows it." : "Video is re-encoded at the chosen size.")
                } else if targetKind == .audio, target == "mp3" || target == "m4a" {
                    bitrate
                }
            case .unsupported:
                EmptyView()
            }
            LabeledContent("Save to") {
                HStack {
                    Text(model.options.destination?.lastPathComponent ?? "Beside original").lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder).controlSize(.small)
                    if model.options.destination != nil {
                        Button("Reset") { model.options.destination = nil }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.columns)
        .font(.callout)
    }

    private var bitrate: some View {
        Picker("Bitrate", selection: $model.options.audioBitrate) {
            Text("128 kbps").tag(128)
            Text("192 kbps").tag(192)
            Text("256 kbps").tag(256)
            Text("320 kbps").tag(320)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

struct RunningView: View {
    @ObservedObject var model: TrayModel

    var body: some View {
        SourceRow(files: model.jobFiles)
        VStack(alignment: .leading, spacing: 6) {
            Text(status).font(.callout)
            if let progress = model.progress, model.phase == .running {
                ProgressView(value: progress).accessibilityLabel("Conversion progress")
            } else {
                ProgressView().progressViewStyle(.linear).accessibilityLabel(status)
            }
        }
        HStack {
            Text("You can close this; conversion continues.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.cancel() }
                .disabled(model.phase == .canceling)
        }
    }

    private var status: String {
        let label = FileFormat.all.first { $0.id == model.jobTarget }?.label ?? ""
        if model.phase == .canceling { return "Canceling…" }
        if model.jobFiles.count > 1 {
            return "Converting to \(label) — \(min(model.outcomes.count + 1, model.jobFiles.count)) of \(model.jobFiles.count)"
        }
        return "Converting to \(label)…"
    }
}

struct ResultView: View {
    @ObservedObject var model: TrayModel
    let actions: TrayActions

    private var done: [ConversionResult] { model.outcomes.compactMap(\.output) }
    private var failed: [FileOutcome] { model.outcomes.filter { $0.output == nil && !$0.wasCanceled } }
    private var canceled: Bool { model.outcomes.contains(where: \.wasCanceled) }

    var body: some View {
        if done.count == 1, model.outcomes.count == 1 {
            OutputRow(result: done[0])
        } else if !done.isEmpty {
            Label("\(done.count) of \(model.jobFiles.count) converted", systemImage: "checkmark.circle.fill")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(done, id: \.output) { OutputRow(result: $0, compact: true) }
                }
            }
            .frame(maxHeight: 180)
        }
        if canceled {
            Label("Conversion canceled. Your original files are safe.", systemImage: "xmark.circle")
                .font(.callout)
        }
        ForEach(failed) { outcome in
            VStack(alignment: .leading, spacing: 4) {
                Label(model.jobFiles.count > 1 ? "\(outcome.source.lastPathComponent) wasn't converted" : "Conversion failed",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(outcome.message?.components(separatedBy: "\n\n").first ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            if failed.isEmpty && !canceled {
                Button("Convert Another") { model.reset() }
            } else {
                Button("Other Format") { model.chooseAnotherFormat() }
                if !failed.isEmpty { Button("Choose Folder…") { actions.chooseFolder(true) } }
            }
            Spacer()
            if !failed.isEmpty || canceled {
                Button("Retry") { model.retry() }
            }
            Button("Done") { model.reset(); actions.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct OutputRow: View {
    let result: ConversionResult
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.output.path))
                .resizable()
                .frame(width: compact ? 24 : 40, height: compact ? 24 : 40)
                .onDrag { NSItemProvider(contentsOf: result.output) ?? NSItemProvider() }
                .help("Drag the converted file anywhere")
            VStack(alignment: .leading, spacing: 2) {
                Text(result.output.lastPathComponent)
                    .font(compact ? .callout : .headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([result.output])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(result.output.lastPathComponent) in Finder")
        }
    }

    private var sizeText: String {
        let size = ByteCountFormatter.string(fromByteCount: result.outputBytes, countStyle: .file)
        guard result.inputBytes > 0, result.outputBytes > 0 else { return size }
        let change = Int((Double(result.outputBytes) / Double(result.inputBytes) - 1) * 100)
        return change == 0 ? size : "\(size) · \(change > 0 ? "+" : "")\(change)% vs original"
    }
}
