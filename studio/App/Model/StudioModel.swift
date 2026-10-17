import AppKit
import Foundation
import Observation
import VideobedKit

@Observable @MainActor
final class StudioModel {
    let workspace: Workspace
    var envState: EnvState = .resolving
    var plugins: [PluginManifest] = []
    var pluginIssues: [String: [ValidationIssue]] = [:]
    var chainPresets: [ChainPreset] = []
    var pluginPresets: [String: [PluginPreset]] = [:]

    var source: URL?
    var mode: RenderMode = .preview
    var previewSettings = RenderSettings(start: 0, duration: 5, height: 480, fps: 30)
    private(set) var stack: [LayerItem] = []
    var selection: LayerItem.ID? { didSet { if selection != oldValue { selectionChanged() } } }
    var viewFinal = true { didSet { if viewFinal != oldValue { updatePlayer() } } }
    var autoRender = false
    var notices: [String] = []

    private(set) var sourceStatus: LayerStatus = .idle
    private(set) var finalOutput: LayerOutput?
    private(set) var renderTask: Task<Void, Never>?
    private(set) var isRendering = false
    private(set) var playerItemURL: URL?
    private(set) var logURL: URL?

    // UI requests raised from menus.
    var showNewPlugin = false
    var confirmClearCache = false

    private var renderGeneration = 0
    private var envTask: Task<Void, Never>?
    private var autoRenderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var proxyTask: Task<Void, Never>?
    private var activeObserver: (any NSObjectProtocol)?

    init(root: URL) {
        workspace = Workspace(root: root)
        reloadLibrary()
        loadSession()
        resolveEnvironment(forceRefresh: false)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLibrary() }
        }
    }

    // MARK: Derived

    var effectiveSettings: RenderSettings {
        switch mode {
        case .preview: previewSettings
        case .full: RenderSettings(start: 0, duration: nil, height: nil, fps: previewSettings.fps)
        }
    }

    var environment: ToolEnvironment? { envState.environment }
    var canRender: Bool { environment != nil && source != nil }

    func plugin(_ id: String) -> PluginManifest? { plugins.first { $0.id == id } }

    func item(_ id: LayerItem.ID?) -> LayerItem? { stack.first { $0.id == id } }

    var selectedItem: LayerItem? { item(selection) }

    /// Missing tools for a plugin, or nil while the environment is unresolved.
    func missingTools(_ m: PluginManifest) -> [String]? {
        environment.map { $0.missing(m.requires) }
    }

    // MARK: Environment

    func resolveEnvironment(forceRefresh: Bool) {
        envTask?.cancel()
        envState = .resolving
        refreshBaseStatuses()
        let root = workspace.root
        let progress = DevShellResolver.progressLog(root: root)
        logURL = progress
        envTask = Task {
            do {
                let env = try await DevShellResolver.resolve(root: root, forceRefresh: forceRefresh, progressLog: progress)
                envState = .ready(env)
            } catch is CancellationError {
                return
            } catch {
                envState = .failed(error.localizedDescription)
            }
            refreshBaseStatuses()
        }
    }

    // MARK: Library

    func reloadLibrary() {
        let loaded = workspace.loadPlugins()
        plugins = loaded.plugins
        pluginIssues = loaded.issues
        chainPresets = workspace.loadChainPresets()
        pluginPresets = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, workspace.loadPluginPresets(plugin: $0.id)) })
        reresolveStack()
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
        return spec.enabled ? .idle : .disabled
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

    // MARK: Stack edits

    func addLayer(plugin id: String) {
        guard let m = plugin(id) else { return }
        let item = LayerItem(spec: LayerSpec(plugin: id, enabled: true, params: m.defaults()))
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
        invalidate(from: min(first, destination))
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
        if viewFinal || selectedItem?.output == nil { playerItemURL = nil }
    }

    private func didEdit() {
        scheduleSave()
        guard autoRender, canRender else { return }
        autoRenderTask?.cancel()
        autoRenderTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            render()
        }
    }

    // MARK: Presets

    /// Replaces the stack with a chain preset; params pass through `resolveParams`.
    func load(chain: ChainPreset) {
        cancelRender()
        stack = chain.layers.map { spec in
            var spec = spec
            if let m = plugin(spec.plugin) {
                let r = workspace.resolveParams(spec.params, for: m)
                notices.append(contentsOf: r.warnings)
                spec.params = r.values
            }
            return LayerItem(spec: spec, status: baseStatus(spec))
        }
        selection = stack.first?.id
        invalidate(from: 0)
        didEdit()
    }

    func chainExists(name: String) -> Bool {
        guard let url = try? workspace.chainPresetURL(name: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func saveChain(name: String) throws {
        try workspace.saveChainPreset(ChainPreset(name: name, layers: stack.map(\.spec)))
        chainPresets = workspace.loadChainPresets()
    }

    func deleteChain(_ preset: ChainPreset) {
        do { try workspace.deleteChainPreset(name: preset.name) } catch { notices.append(error.localizedDescription) }
        chainPresets = workspace.loadChainPresets()
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
        guard let url = try? workspace.pluginPresetURL(plugin: plugin, name: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func savePluginPreset(name: String, from id: LayerItem.ID) throws {
        guard let item = item(id) else { return }
        try workspace.savePluginPreset(PluginPreset(name: name, plugin: item.spec.plugin, params: item.spec.params))
        pluginPresets[item.spec.plugin] = workspace.loadPluginPresets(plugin: item.spec.plugin)
    }

    func deletePluginPreset(_ preset: PluginPreset) {
        do { try workspace.deletePluginPreset(plugin: preset.plugin, name: preset.name) } catch { notices.append(error.localizedDescription) }
        pluginPresets[preset.plugin] = workspace.loadPluginPresets(plugin: preset.plugin)
    }

    // MARK: Plugins

    /// Writes a starter manifest for `name`; returns its id.
    func createPlugin(name: String) throws -> String {
        let id = try Slug.slug(name)
        guard !FileManager.default.fileExists(atPath: workspace.pluginsDir.appending(path: "\(id).json").path) else {
            throw StudioError("a plugin with id '\(id)' already exists")
        }
        let m = PluginManifest(id: id, name: name, summary: "", requires: ["ffmpeg"], steps: [
            PluginStep(name: "encode", argv: ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
                                              "-i", "{in}", "-c:v", "ffv1", "-y", "{out}"]),
        ])
        try workspace.savePlugin(m)
        reloadLibrary()
        return id
    }

    // MARK: Rendering

    private struct ChainSnapshot {
        let source: URL
        let settings: RenderSettings
        let ids: [LayerItem.ID]
        let layers: [LayerSpec]
    }

    func render() {
        guard let env = environment, let source else { return }
        autoRenderTask?.cancel()
        let previous = renderTask
        previous?.cancel()
        let snap = ChainSnapshot(source: source, settings: effectiveSettings, ids: stack.map(\.id), layers: stack.map(\.spec))
        renderGeneration += 1
        let generation = renderGeneration
        isRendering = true
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
        autoRenderTask?.cancel()
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
                case .finished(let out):
                    if stillCurrent(snap, through: nil) { finalOutput = out }
                }
            }
            // A cancelled consumer ends the stream without throwing.
            if Task.isCancelled { resetRunning() } else { updatePlayer() }
        } catch is CancellationError {
            resetRunning()
        } catch let failure as RenderFailure {
            setStatus(snap, failure.index, .failed(failure.underlying.localizedDescription))
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
        if !viewFinal { updatePlayer() }
    }

    /// Output whose proxy the viewer should show.
    var viewedOutput: LayerOutput? {
        viewFinal ? finalOutput : selectedItem?.output
    }

    func updatePlayer() {
        proxyTask?.cancel()
        guard let out = viewedOutput, let env = environment else { playerItemURL = nil; return }
        proxyTask = Task {
            do {
                let url = try await ProxyMaker.proxy(for: out, env: env)
                guard !Task.isCancelled, viewedOutput == out else { return }
                playerItemURL = url
            } catch is CancellationError {
            } catch {
                notices.append("proxy: \(error.localizedDescription)")
            }
        }
    }

    func revealInFinder() {
        guard let dir = viewedOutput?.dir ?? selectedItem?.output?.dir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    func clearCache() {
        cancelRender()
        do { try CacheCleaner.clear(root: workspace.root) } catch { notices.append(error.localizedDescription) }
        sourceStatus = .idle
        invalidate(from: 0)
        playerItemURL = nil
    }

    // MARK: Session

    private var sessionURL: URL { workspace.studioDir.appending(path: "session.json") }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveSession()
        }
    }

    func saveSession() {
        let state = SessionState(source: source?.path, mode: mode, previewSettings: previewSettings, layers: stack.map(\.spec))
        do { try Workspace.write(state, to: sessionURL) } catch { notices.append("session: \(error.localizedDescription)") }
    }

    private func loadSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        if let path = state.source, FileManager.default.fileExists(atPath: path) { source = URL(filePath: path) }
        mode = state.mode
        previewSettings = state.previewSettings
        stack = state.layers.map { LayerItem(spec: $0, status: baseStatus($0)) }
        selection = stack.first?.id
        reresolveStack()
    }
}
