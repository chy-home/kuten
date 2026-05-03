import AppKit
import Foundation

protocol SplitCoordinatorDelegate: AnyObject {
    func splitCoordinatorDidStart(totalJobs: Int, workerCount: Int)
    func splitCoordinatorDidUpdate(completed: Int, failed: Int, total: Int)
    func splitCoordinatorDidFinish(completed: Int, failed: Int, total: Int)
}

final class SplitCoordinator {
    private let jobs: [FFmpegJob]
    private let runtime: RuntimeConfiguration
    private var workers: [WorkerRunner] = []
    private var nextJobOffset = 0
    private var runningJobs = 0
    private var completedJobs = 0
    private var failedJobs = 0
    private var finished = false

    weak var delegate: SplitCoordinatorDelegate?

    init(jobs: [FFmpegJob], concurrency: Int, runtime: RuntimeConfiguration) {
        self.jobs = jobs
        self.runtime = runtime

        let workerCount = max(1, min(concurrency, max(1, jobs.count)))
        self.workers = (1...workerCount).map { WorkerRunner(workerIndex: $0, totalWorkers: workerCount, runtime: runtime) }
        for worker in self.workers {
            worker.onCompletion = { [weak self, weak worker] success in
                guard let self, let worker else {
                    return
                }
                self.handleCompletion(from: worker, success: success)
            }
        }
    }

    func start() {
        guard !jobs.isEmpty else {
            delegate?.splitCoordinatorDidFinish(completed: 0, failed: 0, total: 0)
            return
        }

        for worker in workers {
            worker.windowController.prepareForDisplay()
            worker.windowController.setIdle()
        }

        delegate?.splitCoordinatorDidStart(totalJobs: jobs.count, workerCount: workers.count)
        for worker in workers {
            scheduleNext(for: worker)
        }
    }

    private func scheduleNext(for worker: WorkerRunner) {
        if nextJobOffset >= jobs.count {
            worker.windowController.setIdle(detail: "当前没有待处理任务")
            finishIfNeeded()
            return
        }

        let job = jobs[nextJobOffset]
        let position = nextJobOffset + 1
        nextJobOffset += 1

        do {
            try worker.run(job: job, position: position, total: jobs.count)
            runningJobs += 1
        } catch {
            failedJobs += 1
            worker.windowController.appendLog("启动失败：\(error.localizedDescription)\n")
            worker.windowController.setFinished(success: false, detail: "任务启动失败")
            delegate?.splitCoordinatorDidUpdate(completed: completedJobs, failed: failedJobs, total: jobs.count)
            scheduleNext(for: worker)
        }
    }

    private func handleCompletion(from worker: WorkerRunner, success: Bool) {
        runningJobs = max(0, runningJobs - 1)
        if success {
            completedJobs += 1
        } else {
            failedJobs += 1
        }

        delegate?.splitCoordinatorDidUpdate(completed: completedJobs, failed: failedJobs, total: jobs.count)
        scheduleNext(for: worker)
    }

    private func finishIfNeeded() {
        guard !finished else {
            return
        }

        let processedJobs = completedJobs + failedJobs
        if processedJobs == jobs.count && runningJobs == 0 {
            finished = true
            delegate?.splitCoordinatorDidFinish(completed: completedJobs, failed: failedJobs, total: jobs.count)
        }
    }
}

final class WorkerRunner: NSObject {
    let windowController: WorkerWindowController
    private let runtime: RuntimeConfiguration
    private var process: Process?
    private var logPipe: Pipe?
    var onCompletion: ((Bool) -> Void)?

    init(workerIndex: Int, totalWorkers: Int, runtime: RuntimeConfiguration) {
        self.windowController = WorkerWindowController(workerIndex: workerIndex, totalWorkers: totalWorkers)
        self.runtime = runtime
    }

    func run(job: FFmpegJob, position: Int, total: Int) throws {
        let process = Process()
        process.executableURL = runtime.ffmpegURL
        process.arguments = job.executionArguments
        process.environment = runtime.subprocessEnvironment
        process.currentDirectoryURL = job.outputURL.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice

        let logPipe = Pipe()
        process.standardOutput = logPipe
        process.standardError = logPipe

        self.process = process
        self.logPipe = logPipe

        DispatchQueue.main.async {
            self.windowController.setRunning(job: job, position: position, total: total)
        }

        logPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.windowController.appendLog(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else {
                return
            }

            self.logPipe?.fileHandleForReading.readabilityHandler = nil
            let remainingData = self.logPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let remainingText = String(data: remainingData, encoding: .utf8) ?? ""
            let success = process.terminationStatus == 0

            DispatchQueue.main.async {
                if !remainingText.isEmpty {
                    self.windowController.appendLog(remainingText)
                }
                self.windowController.appendLog(success ? "\n>>> 完成\n" : "\n>>> 失败\n")
                self.windowController.setFinished(
                    success: success,
                    detail: success ? "当前任务已完成" : "当前任务执行失败"
                )
                self.process = nil
                self.logPipe = nil
                self.onCompletion?(success)
            }
        }

        try process.run()
    }
}
