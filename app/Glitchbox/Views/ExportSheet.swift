import AppKit
import GlitchboxKit
import SwiftUI
import UniformTypeIdentifiers

/// Export settings, then a save panel. The export itself runs in the model, so the sheet
/// closes as soon as a destination is chosen.
struct ExportSheet: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
    @State private var crf: Int
    @State private var vtQuality: Int
    @State private var showAdvanced = false

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
        _crf = State(initialValue: settings.effectiveX264CRF)
        _vtQuality = State(initialValue: settings.effectiveVideoToolboxQuality)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                formatSection
                sizeSection
                rangeSection
                if settings.format.hasAudio { audioSection }
                advancedSection
            }
            .formStyle(.grouped)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 520, height: 640)
        .onChange(of: settings.format) { normalizeAudioCodec() }
        .onChange(of: settings.preferredContainer) { normalizeAudioCodec() }
        .onChange(of: settings.quality) {
            settings.x264CRF = nil
            settings.videoToolboxQuality = nil
            crf = settings.effectiveX264CRF
            vtQuality = settings.effectiveVideoToolboxQuality
        }
        .onChange(of: crf) { if crf != settings.quality.x264CRF { settings.x264CRF = crf } }
        .onChange(of: vtQuality) { if vtQuality != settings.quality.videoToolboxQuality { settings.videoToolboxQuality = vtQuality } }
        .onAppear { normalizeAudioCodec() }
        .fileImporter(isPresented: $choosingAudio, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result {
                audioFile = url
            } else if audioFile == nil {
                audioChoice = .none
            }
        }
    }

    // MARK: Sections

    private var formatSection: some View {
        Section("Format") {
            Picker("Format", selection: $settings.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if settings.format.containers.count > 1 {
                Picker("Container", selection: $settings.preferredContainer) {
                    ForEach(settings.format.containers, id: \.self) { Text($0.title).tag($0) }
                }
            }
            switch settings.format {
            case .h264, .hevc:
                Picker("Quality", selection: $settings.quality) {
                    ForEach(ExportQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            case .prores:
                Picker("Profile", selection: $settings.proresProfile) {
                    ForEach(ProResProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            case .ffv1:
                LabeledContent("Quality", value: "Lossless")
            case .gif, .pngSequence:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var sizeSection: some View {
        Section("Size") {
            if settings.format == .gif {
                Picker("Width", selection: $settings.gif.width) {
                    ForEach(GIFOptions.widths, id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                    Text("As rendered").tag(Int?.none)
                }
                Picker("GIF frame rate", selection: $settings.gif.fps) {
                    ForEach(GIFOptions.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
            } else {
                Picker("Size", selection: $sizeChoice) {
                    Text("As rendered").tag(ExportSizeChoice.asRendered)
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
                TextField("Duration (s)", value: $render.stillDuration, format: .number)
            } else {
                Picker("Range", selection: $render.range) {
                    Text("Whole clip").tag(RenderOptions.Range.whole)
                    Text("In/Out").tag(RenderOptions.Range.inOut)
                }
                .pickerStyle(.segmented)
                if render.range == .inOut {
                    TextField("In (s)", value: $render.inPoint, format: .number)
                    TextField("Out (s)", value: $render.outPoint, format: .number, prompt: Text("End"))
                }
            }
            ResolutionPicker(title: "Render at", selection: $render.height)
            LabeledContent("Frame rate", value: frameRateLabel)
        }
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
    private var advancedSection: some View {
        let format = settings.format
        if format == .h264 || format == .hevc || format == .gif {
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    if format == .h264 {
                        Picker("Encoder", selection: $settings.h264Encoder) {
                            ForEach(H264Encoder.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    if format == .h264 && settings.h264Encoder == .x264 {
                        Picker("Preset", selection: $settings.x264Preset) {
                            ForEach(H264Encoder.x264Presets, id: \.self) { Text($0).tag($0) }
                        }
                        Stepper("CRF \(crf)", value: $crf, in: 0...51)
                            .help("Lower is better quality and larger files")
                    } else if format == .h264 || format == .hevc {
                        LabeledContent("Quality \(vtQuality)") {
                            Slider(value: vtQualityValue, in: 1...100, step: 1)
                        }
                        .help("VideoToolbox quality from 1 to 100")
                    }
                    if format == .gif { gifAdvanced }
                }
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

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .monospacedDigit()
                if let warning = gifWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") { chooseDestination() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
        }
    }

    // MARK: Derived

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
        var parts: [String] = []
        if let dimensions { parts.append("\(dimensions.width) × \(dimensions.height)") }
        if let duration { parts.append(duration.formatted(.number.precision(.fractionLength(1))) + " s") }
        if let gifBytes { parts.append("about " + gifBytes.formatted(.byteCount(style: .file))) }
        return parts.isEmpty ? "Choose a source to see the output size" : parts.joined(separator: " · ")
    }

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
        let url: URL
        if final.format.isSequence {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose a folder for the PNG frames. Frames from an earlier export there are replaced."
            panel.directoryURL = model.exportDirectory
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [contentType]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = final.defaultFileName(source: model.source)
            panel.directoryURL = model.exportDirectory
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        model.exportSettings = final
        model.startExport(render: renderSettings, to: url)
        dismiss()
    }
}
