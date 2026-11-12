import Foundation
import Observation
import GlitchboxKit
#if os(macOS)
import AppKit
#endif

@Observable @MainActor
final class StudioModel {
    let workspace: Workspace
    /// Where the base library and toolchain live.
    let paths: AppPaths
    private(set) var envState: EnvState
    var plugins: [PluginManifest] = []
    var pluginIssues: [String: [ValidationIssue]] = [:]
    var chainPresets: [ChainPreset] = []
    var pluginPresets: [String: [PluginPreset]] = [:]
    /// Library origins, refreshed with the entries they describe.
    private(set) var pluginOrigins: [String: LibraryOrigin] = [:]
    private(set) var chainOrigins: [String: LibraryOrigin] = [:]
    private(set) var pluginPresetOrigins: [String: [String: LibraryOrigin]] = [:]

    var source: URL? { didSet { if source != oldValue { probeSource() } } }
    var renderOptions = RenderOptions() { didSet { if renderOptions != oldValue { scheduleSave() } } }
    /// ffprobe of `source`; nil until probed or when probing fails.
    private(set) var sourceProbe: MediaProbe?
    private(set) var stack: [LayerItem] = []
    var selection: LayerItem.ID? { didSet { if selection != oldValue { selectionChanged() } } }
    var viewFinal = true { didSet { if viewFinal != oldValue { updatePlayer() } } }
    var autoRender = false { didSet { if autoRender != oldValue { scheduleSave() } } }
    /// Simple or Advanced: two views of the same session. A new install starts in Simple;
    /// `loadSession` puts sessions saved before modes existed in Advanced.
    var mode = StudioMode.simple { didSet { if mode != oldValue { modeChanged() } } }
    var notices: [String] = []

    private(set) var sourceStatus: LayerStatus = .idle
    private(set) var finalOutput: LayerOutput?
    private(set) var renderTask: Task<Void, Never>?
    private(set) var isRendering = false
    /// True while an edit waits out the auto-render delay.
    private(set) var isRenderPending = false
    /// True while the viewed output's player proxy is being made.
    private(set) var isMakingProxy = false
    private(set) var playerItemURL: URL?
    private(set) var logURL: URL?

    // UI requests raised from menus.
    var showNewPlugin = false
    var showSaveChain = false
    var confirmClearCache = false
    var showExport = false { didSet { if showExport != oldValue { pruneImports() } } }
    /// Opens the plugin editor (a window on macOS, a sheet on iOS).
    var editingPlugin: PluginEditorRequest?
    var showLicenses = false

    // MARK: Export state

    /// Plays the viewed layer's proxy; its playhead picks the frame for Export Current Frame.
    let player = PlayerController()
    var exportSettings: ExportSettings { didSet { if exportSettings != oldValue { saveExportPreferences() } } }
    var exportDirectory: URL? { didSet { if exportDirectory != oldValue { saveExportPreferences() } } }
    private(set) var exportTask: Task<Void, Never>?
    /// Phase text and progress of the running export.
    private(set) var exportPhase = ""
    private(set) var exportFraction: Double?
    var exportOutcome: ExportOutcome?

    private var renderGeneration = 0
    /// True while the running render was started by the user rather than by auto-render.
    private(set) var renderIsUserInitiated = false
    /// Whether the last render ran to the end without failing or being cancelled.
    private(set) var lastRenderSucceeded = false
    private var autoRenderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var proxyTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?

    init(paths: AppPaths) {
        let workspace = Workspace.standard(base: paths.base, environment: ProcessInfo.processInfo.environment)
        self.workspace = workspace
        self.paths = paths
        envState = ToolchainLoader.load(workspace: workspace, paths: paths)
        let prefs = ExportPreferences.load(from: workspace.user.appending(path: "export.json"))
        var settings = prefs.settings
        settings.audio = StoredPath.resolveAudio(settings.audio, in: workspace)
        exportSettings = settings
        exportDirectory = prefs.directory.map { StoredPath.resolve($0, in: workspace) }
        reloadLibrary()
        loadSession()
        probeSource()
        pruneImports()
        #if os(macOS)
        // App-lifetime, so it fires while the main window is closed too.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLibrary() }
        }
        #endif
    }

    func editPlugin(_ id: String) { editingPlugin = PluginEditorRequest(id: id) }

    // MARK: Derived

    var sourceIsStill: Bool { source.map(SourcePrep.isStill) ?? false }

    var effectiveSettings: RenderSettings { renderOptions.settings(still: sourceIsStill) }

    var isExporting: Bool { exportTask != nil }

    var environment: ToolEnvironment? { envState.environment }
    var canRender: Bool { environment != nil && source != nil }

    /// Simple mode always renders after edits; Advanced follows the Auto-render toggle.
    var autoRenders: Bool { autoRender || mode == .simple }

    /// Simple mode always plays the final output.
    private var showsFinal: Bool { viewFinal || mode == .simple }

    private func modeChanged() {
        scheduleSave()
        updatePlayer()
        if mode == .simple, canRender, finalOutput == nil, !isRendering, !isExporting { render(userInitiated: false) }
    }

    /// A layer whose inspector the Advanced layout should show; it clears this once it has.
    var layerToInspect: LayerItem.ID?

    /// Leaves Simple for Advanced. With `layer` (a card's "All Controls…"), Advanced opens on
    /// that layer's parameters.
    func openAdvanced(layer: LayerItem.ID? = nil) {
        if let layer {
            selection = layer
            layerToInspect = layer
        }
        mode = .advanced
    }

    /// Plugin name for the current mode.
    func title(of plugin: PluginManifest) -> String { mode == .simple ? plugin.simpleName : plugin.name }

    func plugin(_ id: String) -> PluginManifest? { plugins.first { $0.id == id } }

    func item(_ id: LayerItem.ID?) -> LayerItem? { stack.first { $0.id == id } }

    var selectedItem: LayerItem? { item(selection) }

    /// Missing tools for a plugin, or nil while the toolchain is unavailable.
    func missingTools(_ m: PluginManifest) -> [String]? {
        environment.map { $0.missing(for: m) }
    }

    /// A still-input plugin (Still Motion) to offer for a still source that has none in its
    /// stack, unless the offer was dismissed for this source or the plugin's tools are missing.
    var suggestedStillPlugin: PluginManifest? {
        guard sourceIsStill, let source, stillSuggestionDismissed != source,
              !stack.contains(where: { plugin($0.spec.plugin)?.input == .still }) else { return nil }
        return plugins.first { $0.input == .still && (missingTools($0) ?? []).isEmpty }
    }

    /// The source whose still-input offer was dismissed; choosing another source offers it again.
    private var stillSuggestionDismissed: URL?

    func dismissStillSuggestion() { stillSuggestionDismissed = source }

    /// Unknown entries count as built-in, so delete stays disabled.
    func origin(of chain: ChainPreset) -> LibraryOrigin { chainOrigins[chain.name] ?? .builtin }

    func origin(of preset: PluginPreset) -> LibraryOrigin { pluginPresetOrigins[preset.plugin]?[preset.name] ?? .builtin }

    // MARK: Toolchain

    /// Re-reads toolchain.json.
    func reloadToolchain() {
        envState = ToolchainLoader.load(workspace: workspace, paths: paths)
        refreshBaseStatuses()
        if sourceProbe == nil { probeSource() }
    }

    // MARK: Library

    func reloadLibrary() {
        let loaded = workspace.loadPlugins()
        plugins = loaded.plugins
        pluginIssues = loaded.issues
        pluginOrigins = Dictionary(uniqueKeysWithValues: plugins.compactMap { p in workspace.pluginOrigin(id: p.id).map { (p.id, $0) } })
        refreshChainPresets()
        pluginPresets = [:]
        pluginPresetOrigins = [:]
        for p in plugins { refreshPluginPresets(p.id) }
        reresolveStack()
    }

    private func refreshChainPresets() {
        chainPresets = workspace.loadChainPresets()
        chainOrigins = Dictionary(chainPresets.compactMap { c in workspace.chainPresetOrigin(name: c.name).map { (c.name, $0) } },
                                  uniquingKeysWith: { a, _ in a })
    }

    private func refreshPluginPresets(_ plugin: String) {
        let presets = workspace.loadPluginPresets(plugin: plugin)
        pluginPresets[plugin] = presets
        pluginPresetOrigins[plugin] = Dictionary(
            presets.compactMap { p in workspace.pluginPresetOrigin(plugin: plugin, name: p.name).map { (p.name, $0) } },
            uniquingKeysWith: { a, _ in a })
    }

    /// Re-applies manifests to the stack after plugins change on disk.
    private func reresolveStack() {
        var changedFrom: Int?
        for i in stack.indices {
            guard let m = plugin(stack[i].spec.plugin) else { continue }
            let r = workspace.resolveParams(stack[i].spec.params, for: m)
            notices.append(contentsOf: r.warnings)
            if r.values != stack[i].spec.params {
                stack[i].spec.params = r.values
                changedFrom = changedFrom ?? i
            }
        }
        if let changedFrom { invalidate(from: changedFrom); didEdit() } else { refreshBaseStatuses() }
    }

    private func baseStatus(_ spec: LayerSpec) -> LayerStatus {
        guard let m = plugin(spec.plugin) else { return .unavailable("missing plugin \(spec.plugin)") }
        if let missing = missingTools(m), !missing.isEmpty { return .unavailable("missing: \(missing.joined(separator: ", "))") }
        if m.input == .still, !sourceIsStill { return .unavailable("needs a still image source") }
        if needsSound(spec, m) { return .unavailable("needs a sound file") }
        return spec.enabled ? .idle : .disabled
    }

    /// A layer driven by the clip's own sound, on a clip that has none, with no file chosen
    /// in its place. False until the source has been probed.
    private func needsSound(_ spec: LayerSpec, _ m: PluginManifest) -> Bool {
        guard m.readsSourceAudio, let probe = sourceProbe, probe.audio == nil else { return false }
        return m.params.filter { $0.type == .file }.allSatisfy { (spec.params[$0.key]?.stringValue ?? "").isEmpty }
    }

    /// Resets non-result statuses (idle/unavailable/disabled) to match plugins and tools.
    private func refreshBaseStatuses() {
        for i in stack.indices {
            switch stack[i].status {
            case .idle, .unavailable, .disabled: stack[i].status = baseStatus(stack[i].spec)
            default: break
            }
        }
    }

    /// Still-input layers read the source image, so the first one is kept at the top. True if it moved.
    private func pinStillInput() -> Bool {
        guard let j = stack.firstIndex(where: { plugin($0.spec.plugin)?.input == .still }), j != 0 else { return false }
        stack.move(fromOffsets: [j], toOffset: 0)
        return true
    }

    // MARK: Stack edits

    func addLayer(plugin id: String) {
        guard let m = plugin(id) else { return }
        let item = LayerItem(spec: LayerSpec(plugin: id, enabled: true, params: m.defaults()))
        if m.input == .still {
            // One still-input layer, always first: it replaces any other.
            stack.removeAll { plugin($0.spec.plugin)?.input == .still }
            stack.insert(item, at: 0)
            selection = item.id
            invalidate(from: 0)
            didEdit()
            return
        }
        stack.append(item)
        stack[stack.count - 1].status = baseStatus(item.spec)
        selection = item.id
        didEdit()
    }

    func removeLayers(_ offsets: IndexSet) {
        guard let first = offsets.min() else { return }
        stack.remove(atOffsets: offsets)
        invalidate(from: first)
        didEdit()
    }

    func removeLayer(_ id: LayerItem.ID) {
        if let i = stack.firstIndex(where: { $0.id == id }) { removeLayers([i]) }
    }

    func moveLayers(_ offsets: IndexSet, to destination: Int) {
        guard let first = offsets.min() else { return }
        stack.move(fromOffsets: offsets, toOffset: destination)
        let pinned = pinStillInput()
        invalidate(from: pinned ? 0 : min(first, destination))
        didEdit()
    }

    func setEnabled(_ id: LayerItem.ID, _ enabled: Bool) {
        guard let i = stack.firstIndex(where: { $0.id == id }), stack[i].spec.enabled != enabled else { return }
        stack[i].spec.enabled = enabled
        invalidate(from: i)
        didEdit()
    }

    func setParam(_ id: LayerItem.ID, key: String, value: ParamValue) {
        guard let i = stack.firstIndex(where: { $0.id == id }), stack[i].spec.params[key] != value else { return }
        stack[i].spec.params[key] = value
        invalidate(from: i)
        didEdit()
    }

    func setParams(_ id: LayerItem.ID, _ params: [String: ParamValue]) {
        guard let i = stack.firstIndex(where: { $0.id == id }), stack[i].spec.params != params else { return }
        stack[i].spec.params = params
        invalidate(from: i)
        didEdit()
    }

    /// Source, mode, or settings changed: every layer is stale.
    func inputsChanged() {
        sourceStatus = .idle
        invalidate(from: 0)
        didEdit()
    }

    private func invalidate(from index: Int) {
        for i in stack.indices where i >= index {
            stack[i].output = nil
            stack[i].status = baseStatus(stack[i].spec)
        }
        finalOutput = nil
        if showsFinal || selectedItem?.output == nil { playerItemURL = nil }
    }

    private func didEdit() {
        scheduleSave()
        // Exports pause auto-render; `exportFinished` catches up.
        guard autoRenders, canRender, !isExporting else { return }
        autoRenderTask?.cancel()
        isRenderPending = true
        autoRenderTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            isRenderPending = false
            render(userInitiated: false)
        }
    }

    // MARK: Presets

    /// Name of the chain last loaded; highlights its cell in the Looks gallery.
    private(set) var appliedLook: String?
    /// The loaded chain's layers, minus still-input ones, as resolved at load.
    private var lookBaseline: [LayerSpec]?

    /// After a relaunch the session only has layers: if they are exactly a library look
    /// (ignoring a still-input layer), that look is the applied one again, so its gallery cell
    /// is outlined and switching looks doesn't ask about changes nobody made.
    private func recognizeAppliedLook() {
        let specs = stack.map(\.spec).filter { !readsStill($0) }
        guard !specs.isEmpty else { return }
        let match = chainPresets.first { chain in
            let resolved = chain.layers.filter { !readsStill($0) }.map { layer in
                var layer = layer
                if let m = plugin(layer.plugin) { layer.params = workspace.resolveParams(layer.params, for: m).values }
                return layer
            }
            return resolved == specs
        }
        guard let match else { return }
        appliedLook = match.name
        lookBaseline = specs
    }

    private func readsStill(_ spec: LayerSpec) -> Bool { plugin(spec.plugin)?.input == .still }

    /// Whether `chain` has a still-input layer, so it only works on a photo.
    func readsStill(_ chain: ChainPreset) -> Bool { chain.layers.contains(where: readsStill) }

    /// What a look lacks on the current source, for the gallery: a photo (it can't run at
    /// all) or sound (it runs once a sound file is chosen on its card).
    func missingInput(for chain: ChainPreset) -> (note: String, blocks: Bool)? {
        guard source != nil else { return nil }
        if !sourceIsStill, readsStill(chain) { return ("Needs a photo", true) }
        let silent = chain.layers.contains { layer in plugin(layer.plugin).map { needsSound(layer, $0) } ?? false }
        return silent ? ("Needs sound", false) : nil
    }

    /// True when the stack (ignoring a still-input layer) differs from the chain last loaded.
    var lookIsModified: Bool {
        let specs = stack.map(\.spec).filter { !readsStill($0) }
        return !specs.isEmpty && specs != lookBaseline
    }

    /// Replaces the stack with a chain preset; params pass through `resolveParams`.
    /// `keepingStillInput` carries the stack's still-input layer over to a chain without one,
    /// so photo motion survives switching looks.
    func load(chain: ChainPreset, keepingStillInput: Bool = false) {
        cancelRender()
        var layers = chain.layers
        if keepingStillInput, sourceIsStill, !readsStill(chain),
           let motion = stack.first(where: { readsStill($0.spec) }) {
            layers.insert(motion.spec, at: 0)
        }
        stack = layers.map { spec in
            var spec = spec
            if let m = plugin(spec.plugin) {
                let r = workspace.resolveParams(spec.params, for: m)
                notices.append(contentsOf: r.warnings)
                spec.params = r.values
            }
            return LayerItem(spec: spec, status: baseStatus(spec))
        }
        _ = pinStillInput()
        appliedLook = chain.name
        lookBaseline = stack.map(\.spec).filter { !readsStill($0) }
        selection = stack.first?.id
        invalidate(from: 0)
        didEdit()
    }

    /// Whether `preset` resolves to exactly the layer's current params.
    func isActive(_ preset: PluginPreset, on item: LayerItem) -> Bool {
        guard let m = plugin(item.spec.plugin) else { return false }
        return workspace.resolveParams(preset.params, for: m).values == item.spec.params
    }

    func chainExists(name: String) -> Bool {
        workspace.chainPresetOrigin(name: name) != nil
    }

    func saveChain(name: String) throws {
        try workspace.saveChainPreset(ChainPreset(name: name, layers: stack.map(\.spec)))
        refreshChainPresets()
        // The stack is now this look, unmodified.
        appliedLook = name
        lookBaseline = stack.map(\.spec).filter { !readsStill($0) }
    }

    /// Deletes a user chain or reverts an overridden built-in.
    func deleteChain(_ preset: ChainPreset) {
        do { try workspace.deleteChainPreset(name: preset.name) } catch { notices.append(error.localizedDescription) }
        refreshChainPresets()
    }

    func apply(preset: PluginPreset, to id: LayerItem.ID) {
        guard let item = item(id), let m = plugin(item.spec.plugin) else { return }
        let r = workspace.resolveParams(preset.params, for: m)
        notices.append(contentsOf: r.warnings)
        setParams(id, r.values)
    }

    func resetToDefaults(_ id: LayerItem.ID) {
        guard let item = item(id), let m = plugin(item.spec.plugin) else { return }
        setParams(id, m.defaults())
    }

    func resetParams(_ id: LayerItem.ID, keys: [String]) {
        guard let item = item(id), let m = plugin(item.spec.plugin) else { return }
        var params = item.spec.params
        for key in keys { params[key] = m.spec(key)?.default }
        setParams(id, params)
    }

    func pluginPresetExists(plugin: String, name: String) -> Bool {
        workspace.pluginPresetOrigin(plugin: plugin, name: name) != nil
    }

    func savePluginPreset(name: String, from id: LayerItem.ID) throws {
        guard let item = item(id) else { return }
        try workspace.savePluginPreset(PluginPreset(name: name, plugin: item.spec.plugin, params: item.spec.params))
        refreshPluginPresets(item.spec.plugin)
    }

    /// Deletes a user preset or reverts an overridden built-in.
    func deletePluginPreset(_ preset: PluginPreset) {
        do { try workspace.deletePluginPreset(plugin: preset.plugin, name: preset.name) } catch { notices.append(error.localizedDescription) }
        refreshPluginPresets(preset.plugin)
    }

    // MARK: Plugins

    /// Writes a starter manifest for `name`; returns its id.
    func createPlugin(name: String) throws -> String {
        let id = try Slug.slug(name)
        guard workspace.pluginOrigin(id: id) == nil else {
            throw StudioError("a plugin with id '\(id)' already exists")
        }
        let m = PluginManifest(id: id, name: name, summary: "", requires: ["ffmpeg"], steps: [
            PluginStep(name: "encode", argv: ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
                                              "-i", "{in}", "-c:v", "ffvhuff", "-y", "{out}"]),
        ])
        try workspace.savePlugin(m)
        reloadLibrary()
        return id
    }

    /// Deletes a user plugin or reverts an overridden built-in.
    func deletePlugin(id: String) throws {
        defer { reloadLibrary() }
        try workspace.deletePlugin(id: id)
    }

    // MARK: Rendering

    private struct ChainSnapshot {
        let source: URL
        let settings: RenderSettings
        let ids: [LayerItem.ID]
        let layers: [LayerSpec]
    }

    func render(userInitiated: Bool = true) {
        guard let env = environment, let source else { return }
        cancelAutoRender()
        let previous = renderTask
        previous?.cancel()
        let snap = ChainSnapshot(source: source, settings: effectiveSettings, ids: stack.map(\.id), layers: stack.map(\.spec))
        renderGeneration += 1
        let generation = renderGeneration
        isRendering = true
        renderIsUserInitiated = userInitiated
        lastRenderSucceeded = false
        renderTask = Task {
            await previous?.value
            guard !Task.isCancelled else {
                if generation == renderGeneration { isRendering = false }
                return
            }
            await run(snap, env: env, generation: generation)
        }
    }

    func cancelRender() {
        renderTask?.cancel()
        cancelAutoRender()
    }

    private func cancelAutoRender() {
        autoRenderTask?.cancel()
        isRenderPending = false
    }

    /// True while the chain through snapshot position `index` (nil = whole chain)
    /// still matches the live stack, so a result may be applied to it.
    private func stillCurrent(_ snap: ChainSnapshot, through index: Int?) -> Bool {
        guard snap.source == source, snap.settings == effectiveSettings else { return false }
        let pairs = Array(zip(snap.ids, snap.layers))
        let then: [(LayerItem.ID, LayerSpec)]
        let now: [LayerItem]
        if let index {
            guard let pos = stack.firstIndex(where: { $0.id == snap.ids[index] }) else { return false }
            then = Array(pairs.prefix(index + 1))
            now = Array(stack.prefix(pos + 1))
        } else {
            then = pairs
            now = stack
        }
        let thenEnabled = then.filter { $0.1.enabled }
        let nowEnabled = now.filter(\.spec.enabled)
        return thenEnabled.map(\.0) == nowEnabled.map(\.id) && thenEnabled.map(\.1) == nowEnabled.map(\.spec)
    }

    private func setStatus(_ snap: ChainSnapshot, _ index: Int, _ status: LayerStatus, output: LayerOutput? = nil) {
        if index < 0 {
            if snap.source == source, snap.settings == effectiveSettings { sourceStatus = status }
            return
        }
        guard stillCurrent(snap, through: index), let i = stack.firstIndex(where: { $0.id == snap.ids[index] }) else { return }
        stack[i].status = status
        if let output { stack[i].output = output }
    }

    private func run(_ snap: ChainSnapshot, env: ToolEnvironment, generation: Int) async {
        sourceStatus = .idle
        for i in stack.indices where stack[i].spec.enabled { stack[i].status = baseStatus(stack[i].spec) }
        let renderer = Renderer(env: env, workspace: workspace)
        do {
            for try await event in renderer.render(source: snap.source, layers: snap.layers, settings: snap.settings) {
                switch event {
                case .layerStarted(let index, _):
                    setStatus(snap, index, .running(step: 0, of: 0, name: "starting"))
                case .step(let index, let step, let of, let name, let log):
                    setStatus(snap, index, .running(step: step, of: of, name: name))
                    logURL = log
                case .layerFinished(let index, let out):
                    setStatus(snap, index, .done(cached: out.cached), output: out)
                    logURL = out.dir.appending(path: "log.txt")
                case .finished(let out, _):
                    if stillCurrent(snap, through: nil) { finalOutput = out }
                }
            }
            // A cancelled consumer ends the stream without throwing.
            if Task.isCancelled {
                resetRunning()
            } else {
                updatePlayer()
                if generation == renderGeneration { lastRenderSucceeded = true }
            }
        } catch is CancellationError {
            resetRunning()
        } catch let failure as RenderFailure {
            // A layer already known not to run on this source fails with that reason, not the tool's exit code.
            var message = failure.underlying.localizedDescription
            if snap.layers.indices.contains(failure.index), case .unavailable(let why) = baseStatus(snap.layers[failure.index]) {
                message = why
            }
            setStatus(snap, failure.index, .failed(message))
            if let log = failure.log { logURL = log }
            resetRunning()
        } catch {
            notices.append(error.localizedDescription)
            resetRunning()
        }
        if generation == renderGeneration { isRendering = false }
    }

    private func resetRunning() {
        if case .running = sourceStatus { sourceStatus = .idle }
        for i in stack.indices {
            if case .running = stack[i].status { stack[i].status = baseStatus(stack[i].spec) }
        }
    }

    // MARK: Viewer

    private func selectionChanged() {
        if let out = selectedItem?.output { logURL = out.dir.appending(path: "log.txt") }
        if !showsFinal { updatePlayer() }
    }

    /// Output whose proxy the viewer should show.
    var viewedOutput: LayerOutput? {
        showsFinal ? finalOutput : selectedItem?.output
    }

    func updatePlayer() {
        proxyTask?.cancel()
        guard let out = viewedOutput, let env = environment else {
            playerItemURL = nil
            isMakingProxy = false
            return
        }
        isMakingProxy = true
        proxyTask = Task {
            do {
                let url = try await ProxyMaker.proxy(for: out, env: env)
                if !Task.isCancelled, viewedOutput == out { playerItemURL = url }
            } catch is CancellationError {
            } catch {
                notices.append("proxy: \(error.localizedDescription)")
            }
            // A cancelled task was replaced by a newer `updatePlayer`, which owns the flag now.
            if !Task.isCancelled { isMakingProxy = false }
        }
    }

    // MARK: Source probe

    private func probeSource() {
        probeTask?.cancel()
        sourceProbe = nil
        guard let source, let env = environment else { return }
        probeTask = Task {
            do {
                let probe = try await MediaProbe.probe(source, env: env)
                guard !Task.isCancelled, self.source == source else { return }
                sourceProbe = probe
                // Layers driven by the clip's sound now know whether it has any.
                refreshBaseStatuses()
                if let video = probe.video, ColorTags.isHDR(video) {
                    let kind = video.colorTransfer == "smpte2084" ? "PQ" : "HLG"
                    notices.append("\(source.lastPathComponent) is HDR (\(kind)). Glitchbox renders it as SDR without tone mapping, so colours and brightness will look different from the original.")
                }
            } catch is CancellationError {
            } catch {
                notices.append("probe: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Export

    /// Renders a snapshot of the chain with `render` and encodes it to `destination`. Runs
    /// beside preview renders; auto-render waits until it ends.
    func startExport(render: RenderSettings, to destination: URL) {
        guard let env = environment, let source, exportTask == nil else { return }
        cancelAutoRender()
        exportOutcome = nil
        exportDirectory = destination.deletingLastPathComponent()
        exportPhase = "Starting"
        exportFraction = nil
        let exporter = Exporter(env: env, workspace: workspace)
        let layers = stack.map(\.spec), settings = exportSettings
        exportTask = Task {
            let (events, sink) = AsyncStream.makeStream(of: ExportEvent.self)
            // Runs as a child, so cancelling the export waits for ffmpeg to die and the
            // partial file to be deleted before the toolbar clears.
            async let exported: URL = {
                defer { sink.finish() }
                return try await exporter.export(source: source, layers: layers, render: render, settings: settings,
                                                 to: destination, events: { sink.yield($0) })
            }()
            for await event in events {
                exportPhase = event.label
                switch event {
                case .rendering(let k, let n, _): exportFraction = Double(k) / Double(n + 1)
                case .encoding(let f): exportFraction = f
                case .finished: break
                }
            }
            do {
                exportOutcome = .finished(try await exported)
            } catch is CancellationError {
            } catch let e as ExportError {
                exportOutcome = .failed(message: e.localizedDescription, tail: e.tail)
            } catch let e as RenderFailure {
                exportOutcome = .failed(message: e.localizedDescription, tail: (e.underlying as? RenderError)?.tail ?? [])
            } catch {
                exportOutcome = .failed(message: error.localizedDescription, tail: [])
            }
            if case .finished = exportOutcome {} else { removeEmptiedExport(destination, settings: settings) }
            exportFinished()
        }
    }

    /// iOS creates a fresh folder for each image-sequence export; a failed or cancelled one
    /// shouldn't leave it behind.
    private func removeEmptiedExport(_ destination: URL, settings: ExportSettings) {
        #if os(iOS)
        guard settings.format.isSequence,
              destination.deletingLastPathComponent().standardizedFileURL == PlatformActions.exportsDirectory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: destination)
        #endif
    }

    func cancelExport() {
        guard let exportTask else { return }
        exportPhase = "Cancelling"
        exportTask.cancel()
    }

    private func exportFinished() {
        exportTask = nil
        exportPhase = ""
        exportFraction = nil
        // `render()` cancels and awaits any in-flight preview render, which may be rendering a
        // snapshot that edits made during the export have already invalidated.
        if autoRenders, canRender, finalOutput == nil { render(userInitiated: false) }
    }

    /// Saves the frame under the playhead of the viewed layer as a PNG.
    func exportCurrentFrame(to destination: URL) {
        guard let out = viewedOutput, let env = environment else { return }
        let time = player.player.currentTime().seconds
        let tags = sourceProbe?.video.map(ColorTags.resolve) ?? .bt709
        exportDirectory = destination.deletingLastPathComponent()
        Task {
            do {
                try await Exporter(env: env, workspace: workspace)
                    .exportFrame(of: out.output, at: time.isFinite ? time : 0, sourceTags: tags, to: destination)
                exportOutcome = .finished(destination)
            } catch let e as ExportError {
                exportOutcome = .failed(message: e.localizedDescription, tail: e.tail)
            } catch {
                exportOutcome = .failed(message: error.localizedDescription, tail: [])
            }
        }
    }

    private func saveExportPreferences() {
        var settings = exportSettings
        settings.audio = StoredPath.storeAudio(settings.audio, in: workspace)
        let prefs = ExportPreferences(settings: settings, directory: exportDirectory.map { StoredPath.store($0, in: workspace) })
        do { try Workspace.write(prefs, to: workspace.user.appending(path: "export.json")) } catch {
            notices.append("export settings: \(error.localizedDescription)")
        }
        pruneImports()
    }

    /// Deletes imported media nothing refers to any more (iOS copies picks into the user
    /// library). Waits while the export sheet is open, since it holds a picked audio file
    /// it hasn't committed yet.
    func pruneImports() {
        #if os(iOS)
        guard !showExport else { return }
        var references = [source?.path ?? ""]
        if case .file(let path) = exportSettings.audio { references.append(path) }
        if let layers = try? JSONEncoder().encode(stack.map(\.spec)) {
            references.append(String(decoding: layers, as: UTF8.self))
        }
        ImportedFile.prune(in: workspace, references: references)
        #endif
    }

    func clearCache() {
        guard !isExporting else { return }
        cancelRender()
        do { try workspace.clearLayerCache() } catch { notices.append(error.localizedDescription) }
        sourceStatus = .idle
        invalidate(from: 0)
        playerItemURL = nil
    }

    // MARK: Session

    private var sessionURL: URL { workspace.sessionURL }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveSession()
        }
    }

    func saveSession() {
        let state = SessionState(source: source.map { StoredPath.store($0, in: workspace) }, render: renderOptions,
                                 layers: stack.map(\.spec), autoRender: autoRender, studioMode: mode)
        do { try Workspace.write(state, to: sessionURL) } catch { notices.append("session: \(error.localizedDescription)") }
        pruneImports()
    }

    private func loadSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        // Before the stack: re-resolving it counts as an edit, which Simple mode renders.
        mode = state.studioMode ?? .advanced
        if let stored = state.source {
            let url = StoredPath.resolve(stored, in: workspace)
            if FileManager.default.fileExists(atPath: url.path) { source = url }
        }
        renderOptions = state.render
        stack = state.layers.map { LayerItem(spec: $0, status: baseStatus($0)) }
        selection = stack.first?.id
        reresolveStack()
        autoRender = state.autoRender
        recognizeAppliedLook()
        // Simple mode always shows its result; with auto-render on, Advanced reopens on the last
        // one (a cache hit when it's still cached).
        if canRender, mode == .simple || (autoRender && !stack.isEmpty) { render(userInitiated: false) }
    }
}
