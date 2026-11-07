import BackgroundTasks
import os
import SwiftUI

/// Keeps a user-started render or an export running when the app leaves the foreground,
/// as a BGContinuedProcessingTask: the system shows its progress in a Live Activity, and
/// cancelling there (or the system expiring the task) cancels the work.
/// The app owns one `BackgroundWork`, so there is one task per job whatever the views do.
struct ContinuedProcessing: ViewModifier {
    @Environment(StudioModel.self) private var model
    let work: BackgroundWork

    func body(content: Content) -> some View {
        content
            .onChange(of: job, initial: true) { work.track(job, model: model) }
            .onChange(of: fraction) { work.report(fraction) }
    }

    private var job: BackgroundWork.Job? {
        if model.isExporting { return .export }
        if model.isRendering, model.renderIsUserInitiated { return .render }
        return nil
    }

    private var fraction: Double {
        switch job {
        case .export: return model.exportFraction ?? 0
        case .render:
            let enabled = model.stack.filter(\.spec.enabled)
            guard !enabled.isEmpty else { return 0 }
            let done = enabled.filter { if case .done = $0.status { true } else { false } }.count
            return Double(done) / Double(enabled.count)
        case nil: return 0
        }
    }
}

@MainActor
final class BackgroundWork {
    enum Job: Equatable {
        case render, export

        var title: String { self == .export ? "Exporting" : "Rendering" }
    }

    private static let log = Logger(subsystem: "com.kylegrantlucas.glitchbox", category: "background")
    /// Units of `task.progress`; fractions are scaled to it.
    private static let units: Int64 = 1000

    private var job: Job?
    private var identifier: String?
    private var task: BGContinuedProcessingTask?
    private var fraction = 0.0
    /// Set when the system expired the task; the work it cancels then counts as failed.
    private var expired = false

    /// Whether the job that just ended produced its result.
    private func succeeded(_ model: StudioModel) -> Bool {
        guard !expired else { return false }
        switch job {
        case .export: if case .finished = model.exportOutcome { return true } else { return false }
        case .render: return model.lastRenderSucceeded
        case nil: return false
        }
    }

    func track(_ next: Job?, model: StudioModel) {
        guard next != job else { return }
        finish(success: next == nil && succeeded(model))
        job = next
        guard let next else { return }
        start(next, model: model)
    }

    func report(_ fraction: Double) {
        self.fraction = fraction
        task?.progress.completedUnitCount = Int64(min(max(fraction, 0), 1) * Double(Self.units))
    }

    private func start(_ job: Job, model: StudioModel) {
        let id = "com.kylegrantlucas.glitchbox.work.\(UUID().uuidString)"
        identifier = id
        fraction = 0
        expired = false
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated {
                guard let self, self.identifier == id else { task.setTaskCompleted(success: false); return }
                self.attach(task, model: model)
            }
        }
        guard registered else {
            Self.log.error("could not register \(id, privacy: .public)")
            return
        }
        let subtitle = model.source?.lastPathComponent ?? "Glitchbox"
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: job.title, subtitle: subtitle)
        // Run now or not at all: a queued request would start after the work is done.
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // Without the task the work still runs in the foreground; only backgrounding suspends it.
            Self.log.error("continued processing not granted: \(error.localizedDescription, privacy: .public)")
            identifier = nil
        }
    }

    private func attach(_ task: BGContinuedProcessingTask, model: StudioModel) {
        self.task = task
        task.progress.totalUnitCount = Self.units
        report(fraction)
        let job = self.job
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expired = true
                switch job {
                case .export: model.cancelExport()
                case .render: model.cancelRender()
                case nil: break
                }
            }
        }
    }

    private func finish(success: Bool) {
        if let task {
            if success { task.progress.completedUnitCount = Self.units }
            task.setTaskCompleted(success: success)
        } else if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        task = nil
        identifier = nil
    }
}
