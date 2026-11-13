import GlitchboxKit
import SwiftUI
import UniformTypeIdentifiers

/// Export settings, then a save panel. Three choices cover most exports (what to make, its
/// quality, its size); More Options unfolds every other setting in place and stays open once
/// opened. The export itself runs in the model, so the sheet closes as soon as a destination
/// is chosen.
struct ExportSheet: View {
    /// What the first row calls the formats.
    private enum Kind: Hashable { case video, gif, frames }

    private static let videoFormats: [ExportFormat] = [.h264, .hevc, .prores, .ffv1]
    /// Sizes offered before More Options; the rest are in its Size menu.
    private static let commonSizes: [ExportSizeChoice] = [.asRendered, .shortSide(1080), .shortSide(720), .social(0), .social(1)]

    @Environment(StudioModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportShowsMoreOptions") private var showMore = false

    @State private var settings: ExportSettings
    /// The export's own render: whole clip at native size by default.
    @State private var render: RenderOptions
    @State private var sizeChoice: ExportSizeChoice
    @State private var customWidth: Int
    @State private var customHeight: Int
    @State private var customFit: FitMode
    @State private var noUpscale: Bool
    @State private var audioChoice: ExportAudioChoice
    @State private var audioFile: URL?
    @State private var choosingAudio = false
    @State private var vtQuality: Int
    /// The codec Video last used, restored when coming back from GIF or Frames.
    @State private var videoFormat: ExportFormat

    init(settings: ExportSettings, render: RenderOptions) {
        _settings = State(initialValue: settings)
        _render = State(initialValue: render)
        _sizeChoice = State(initialValue: ExportSizeChoice(settings.size))
        if case .box(let w, let h, let fit) = settings.size {
            _customWidth = State(initialValue: w)
            _customHeight = State(initialValue: h)
            _customFit = State(initialValue: fit)
        } else {
            _customWidth = State(initialValue: 1920)
            _customHeight = State(initialValue: 1080)
            _customFit = State(initialValue: .fit)
        }
        _noUpscale = State(initialValue: !settings.allowUpscale)
        switch settings.audio {
        case .none: _audioChoice = State(initialValue: .none)
        case .source: _audioChoice = State(initialValue: .source)
        case .file(let path):
            _audioChoice = State(initialValue: .file)
            _audioFile = State(initialValue: URL(filePath: path))
        }
        _vtQuality = State(initialValue: settings.effectiveVideoToolboxQuality)
        _videoFormat = State(initialValue: Self.videoFormats.contains(settings.format) ? settings.format : .h264)
    }

    var body: some View {
        withChangeHandlers(layout)
    }

    @ViewBuilder private var layout: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            form
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 520, height: showMore ? 640 : 300)
        #else
        NavigationStack {
            form
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    summaryView
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.bar)
                }
                .navigationTitle("Export")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Export", role: .confirm) { chooseDestination() }
                            .disabled(!canExport)
                    }
                }
        }
        .presentationDetents(showMore ? [.large] : [.medium, .large])
        #endif
    }

    private var form: some View {
        Form {
            essentials
            moreOptionsRow
            if showMore {
                formatSection
                sizeSection
                rangeSection
                if settings.format.hasAudio { audioSection }
                encoderSection
            }
        }
        .formStyle(.grouped)
    }

    /// The sheet's change handlers, applied to whichever platform layout wraps the form.
    private func withChangeHandlers(_ content: some View) -> some View {
        content
        .onChange(of: settings.format) {
            if Self.videoFormats.contains(settings.format) { videoFormat = settings.format }
            normalizeAudioCodec()
        }
        .onChange(of: settings.preferredContainer) { normalizeAudioCodec() }
        .onChange(of: settings.quality) {
            settings.videoToolboxQuality = nil
            vtQuality = settings.effectiveVideoToolboxQuality
        }
        .onChange(of: vtQuality) {
            settings.videoToolboxQuality = vtQuality == settings.quality.videoToolboxQuality ? nil : vtQuality
        }
        .onAppear { normalizeAudioCodec() }
        .fileImporter(isPresented: $choosingAudio, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result {
                do { audioFile = try ImportedFile.adopt(url, into: model.workspace) } catch {
                    model.notices.append("import: \(error.localizedDescription)")
                    if audioFile == nil { audioChoice = .none }
                }
            } else if audioFile == nil {
                audioChoice = .none
            }
        }
    }

    // MARK: Sections

    /// What to make, how good, how big.
    private var essentials: some View {
        Section {
            Picker("Export", selection: kind) {
                Text("Video").tag(Kind.video)
                Text("GIF").tag(Kind.gif)
                Text("Frames").tag(Kind.frames)
            }
            .pickerStyle(.segmented)
            switch settings.format {
            case .h264, .hevc:
                Picker("Quality", selection: $settings.quality) {
                    ForEach(ExportQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("A smaller file, or a cleaner picture")
            case .prores:
                LabeledContent("Quality", value: "ProRes \(settings.proresProfile.title)")
            case .ffv1:
                LabeledContent("Quality", value: "Lossless")
            case .gif:
                Picker("Width", selection: $settings.gif.width) {
                    ForEach(GIFOptions.widths, id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                    Text("Original").tag(Int?.none)
                }
            case .pngSequence:
                LabeledContent("Frames", value: "A folder of PNGs, one per frame")
            }
            if settings.format.usesOutputSize {
                Picker("Size", selection: $sizeChoice) {
                    ForEach(Self.commonSizes, id: \.self) { Text(title(of: $0)).tag($0) }
                    // A size picked under More Options still shows here.
                    if !Self.commonSizes.contains(sizeChoice) { Text(title(of: sizeChoice)).tag(sizeChoice) }
                }
            }
        }
    }

    private var moreOptionsRow: some View {
        Section {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showMore.toggle() }
            } label: {
                HStack {
                    Text("More Options")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showMore ? "Expanded" : "Collapsed")
        } footer: {
            if !showMore { Text("Codec, custom sizes, range, audio, and encoder settings.") }
        }
    }

    @ViewBuilder
    private var formatSection: some View {
        switch settings.format {
        case .h264, .hevc, .prores, .ffv1:
            Section("Format") {
                Picker("Codec", selection: $settings.format) {
                    ForEach(Self.videoFormats, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.format.containers.count > 1 {
                    Picker("Container", selection: $settings.preferredContainer) {
                        ForEach(settings.format.containers, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if settings.format == .prores {
                    Picker("Profile", selection: $settings.proresProfile) {
                        ForEach(ProResProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        case .gif:
            Section("GIF") {
                Picker("Frame rate", selection: $settings.gif.fps) {
                    ForEach(GIFOptions.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                gifAdvanced
            }
        case .pngSequence:
            EmptyView()
        }
    }

    private var sizeSection: some View {
        Section("Size") {
            if settings.format.usesOutputSize {
                Picker("Size", selection: $sizeChoice) {
                    Text(title(of: .asRendered)).tag(ExportSizeChoice.asRendered)
                    Section("Short side") {
                        ForEach(OutputSize.shortSides, id: \.self) { Text("\($0)p").tag(ExportSizeChoice.shortSide($0)) }
                    }
                    Section("Social") {
                        ForEach(OutputSize.social.indices, id: \.self) { i in
                            Text(OutputSize.social[i].title).tag(ExportSizeChoice.social(i))
                        }
                    }
                    Text("Custom").tag(ExportSizeChoice.custom)
                }
                if sizeChoice == .custom {
                    LabeledContent("Width × height") {
                        HStack(spacing: 4) {
                            TextField("Width", value: $customWidth, format: .number.grouping(.never))
                                .frame(width: 70)
                            Text("×")
                            TextField("Height", value: $customHeight, format: .number.grouping(.never))
                                .frame(width: 70)
                        }
                        .labelsHidden()
                    }
                    Picker("Scaling", selection: $customFit) {
                        ForEach(FitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Fit pads with black, Fill crops the overflow, Stretch distorts")
                }
            }
            Toggle("Don't upscale", isOn: $noUpscale)
                .help("Never make the picture larger than it was rendered")
        }
    }

    private var rangeSection: some View {
        Section("Range") {
            if model.sourceIsStill {
                secondsField("Duration (s)", TextField("Duration (s)", value: $render.stillDuration, format: .number))
            } else {
                Picker("Range", selection: $render.range) {
                    Text("Whole clip").tag(RenderOptions.Range.whole)
                    Text("In/Out").tag(RenderOptions.Range.inOut)
                }
                .pickerStyle(.segmented)
                if render.range == .inOut {
                    secondsField("In (s)", TextField("In (s)", value: $render.inPoint, format: .number))
                    secondsField("Out (s)", TextField("Out (s)", value: $render.outPoint, format: .number, prompt: Text("End")))
                }
            }
            ResolutionPicker(title: "Render at", selection: $render.height)
            LabeledContent("Frame rate", value: frameRateLabel)
        }
    }

    /// macOS forms show a text field's title as its label; iOS forms need an explicit one.
    @ViewBuilder private func secondsField(_ title: String, _ field: some View) -> some View {
        #if os(iOS)
        LabeledContent(title) {
            field
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
        }
        #else
        field
        #endif
    }

    private var audioSection: some View {
        Section("Audio") {
            Picker("Audio", selection: $audioChoice) {
                Text("None").tag(ExportAudioChoice.none)
                Text(sourceHasAudio ? "Source" : "Source (no audio)").tag(ExportAudioChoice.source)
                    .disabled(!sourceHasAudio)
                Text("File…").tag(ExportAudioChoice.file)
            }
            .onChange(of: audioChoice) { if audioChoice == .file, audioFile == nil { choosingAudio = true } }
            if audioChoice == .file {
                LabeledContent("File") {
                    HStack {
                        Text(audioFile?.lastPathComponent ?? "None")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosingAudio = true }
                    }
                }
            }
            if audioChoice != .none {
                Picker("Codec", selection: $settings.audioCodec) {
                    ForEach(settings.container.audioCodecs, id: \.self) { Text($0.title).tag(AudioCodec?.some($0)) }
                }
                if settings.effectiveAudioCodec?.hasBitrate == true {
                    Picker("Bitrate", selection: $settings.audioBitrate) {
                        ForEach(AudioCodec.aacBitrates, id: \.self) { Text("\($0) kbit/s").tag($0) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var encoderSection: some View {
        let format = settings.format
        if format == .h264 || format == .hevc {
            Section("Encoder") {
                LabeledContent("Quality \(vtQuality)") {
                    Slider(value: vtQualityValue, in: 1...100, step: 1)
                }
                .help("VideoToolbox quality from 1 to 100")
            }
        }
    }

    @ViewBuilder
    private var gifAdvanced: some View {
        Picker("Dither", selection: $settings.gif.dither) {
            ForEach(GIFDither.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if settings.gif.dither == .bayer {
            Stepper("Bayer scale \(settings.gif.bayerScale)", value: $settings.gif.bayerScale, in: 0...5)
        }
        Picker("Palette", selection: $settings.gif.palette) {
            ForEach(GIFPalette.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .help("A palette per frame keeps colour in fast-changing clips but makes larger files")
        Picker("Loop", selection: $settings.gif.plays) {
            Text("Forever").tag(0)
            Text("Play once").tag(1)
            ForEach([2, 3, 5, 10], id: \.self) { Text("Play \($0) times").tag($0) }
        }
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary)
                .monospacedDigit()
            if let warning = gifWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            summaryView
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") { chooseDestination() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
        }
    }

    // MARK: Derived

    private var kind: Binding<Kind> {
        Binding {
            switch settings.format {
            case .gif: .gif
            case .pngSequence: .frames
            case .h264, .hevc, .prores, .ffv1: .video
            }
        } set: { kind in
            switch kind {
            case .video: settings.format = videoFormat
            case .gif: settings.format = .gif
            case .frames: settings.format = .pngSequence
            }
        }
    }

    private func title(of choice: ExportSizeChoice) -> String {
        switch choice {
        case .asRendered: "Original"
        case .shortSide(let n): "\(n)p"
        case .social(0): "Vertical 9:16"
        case .social(1): "Square 1:1"
        case .social(let i): OutputSize.social[i].title
        case .custom: "Custom (\(customWidth) × \(customHeight))"
        }
    }

    /// The Slider needs a Double; quality is stored as an Int.
    private var vtQualityValue: Binding<Double> {
        Binding(get: { Double(vtQuality) }, set: { vtQuality = Int($0.rounded()) })
    }

    private var sourceHasAudio: Bool { model.sourceProbe?.audio != nil }

    private var frameRateLabel: String {
        if let fps = render.fps { return "\(fps.label) fps" }
        if let rate = model.sourceProbe?.video?.frameRate, !model.sourceIsStill {
            return "\(FrameRate.nearestStandard(to: rate).label) fps (source)"
        }
        return model.sourceIsStill ? "30 fps" : "Source rate"
    }

    private var outputSize: OutputSize {
        switch sizeChoice {
        case .asRendered: .asRendered
        case .shortSide(let n): .shortSide(n)
        case .social(let i): OutputSize.social[i].size
        case .custom: .box(width: customWidth, height: customHeight, fit: customFit)
        }
    }

    /// Everything the sheet controls, folded into one value.
    private var finalSettings: ExportSettings {
        var s = settings
        s.size = outputSize
        s.allowUpscale = !noUpscale
        switch audioChoice {
        case .none: s.audio = .none
        case .source: s.audio = .source
        case .file: s.audio = audioFile.map { .file($0.path) } ?? .none
        }
        return s
    }

    private var renderSettings: RenderSettings { render.settings(still: model.sourceIsStill) }

    /// Seconds of output, when the source has been probed.
    private var duration: Double? {
        let s = renderSettings
        if model.sourceIsStill { return s.stillDuration }
        if let d = s.duration { return d }
        return model.sourceProbe?.duration.map { max(0, $0 - s.start) }
    }

    /// Predicted output size, assuming the layers keep the source-prep size (nearly all do).
    private var dimensions: (width: Int, height: Int)? {
        guard let video = model.sourceProbe?.video else { return nil }
        let rendered = SourcePrep.outputSize(settings: renderSettings, video: video)
        let g = ExportPlan.geometry(video: MediaProbe.Video(width: rendered.width, height: rendered.height),
                                    settings: finalSettings)
        return (g.width, g.height)
    }

    private var gifBytes: Int? {
        guard settings.format == .gif, let dimensions, let duration else { return nil }
        return ExportPlan.estimatedGIFBytes(width: dimensions.width, height: dimensions.height, duration: duration,
                                            options: settings.gif)
    }

    private var summary: String {
        var parts = [settings.format.containers.count > 1 ? "\(settings.format.title) \(settings.container.title)" : settings.format.title]
        if let dimensions { parts.append("\(dimensions.width) × \(dimensions.height)") }
        if let duration { parts.append(duration.formatted(.number.precision(.fractionLength(1))) + " s") }
        if let gifBytes { parts.append("about " + gifBytes.formatted(.byteCount(style: .file))) }
        if settings.format.hasAudio { parts.append(audioChoice == .none || !hasSound ? "no sound" : "sound") }
        return parts.joined(separator: " · ")
    }

    /// Whether the chosen audio will actually be there.
    private var hasSound: Bool { audioChoice == .file ? audioFile != nil : sourceHasAudio }

    private var gifWarning: String? {
        guard let gifBytes, gifBytes > ExportPlan.largeGIFBytes else { return nil }
        return "Large GIF. A smaller width or frame rate will shrink it."
    }

    private var canExport: Bool {
        guard model.canRender, !model.isExporting else { return false }
        if sizeChoice == .custom, customWidth < 2 || customHeight < 2 { return false }
        if !model.sourceIsStill, render.range == .inOut, let out = render.outPoint, out <= render.inPoint { return false }
        if audioChoice == .file, audioFile == nil { return false }
        return true
    }

    private var contentType: UTType {
        switch settings.container {
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .mkv: .matroska
        case .gif: .gif
        case .folder: .folder
        }
    }

    // MARK: Actions

    /// Keeps the codec picker on a value the container accepts.
    private func normalizeAudioCodec() {
        settings.audioCodec = settings.effectiveAudioCodec
    }

    private func chooseDestination() {
        let final = finalSettings
        guard let url = PlatformActions.exportDestination(for: final, contentType: contentType, model: model) else { return }
        model.exportSettings = final
        model.startExport(render: renderSettings, to: url)
        dismiss()
    }
}
