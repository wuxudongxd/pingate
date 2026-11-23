import Foundation
import Darwin

public enum ProfileWatcherError: Error, LocalizedError, Sendable {
    case fileNotAccessible(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .fileNotAccessible(let path, let code):
            return "无法监听文件 \(path)（错误码 errno=\(code)）。"
        }
    }
}

/// Watches a local Clash/FlClash YAML profile using `DispatchSourceFileSystemObject` with debouncing
/// and automatic re-attachment across atomic file replacements (rename/delete + recreate).
public final class ProfileWatcher: @unchecked Sendable {
    public let fileURL: URL
    public let debounceInterval: TimeInterval

    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var pendingWorkItem: DispatchWorkItem?
    private var reattachWorkItem: DispatchWorkItem?
    private var isStopped: Bool = true

    public init(
        fileURL: URL,
        debounceInterval: TimeInterval = 0.8,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.fileURL = fileURL
        self.debounceInterval = max(0.05, debounceInterval)
        self.onChange = onChange
        self.queue = DispatchQueue(label: "com.pingate.profile-watcher.\(UUID().uuidString)")
    }

    deinit {
        stop()
    }

    public func start() throws {
        var startError: Error?
        queue.sync {
            self.isStopped = false
            self.teardownSourceLocked()
            do {
                try self.attachSourceLocked()
            } catch {
                startError = error
            }
        }
        if let startError {
            throw startError
        }
    }

    public func stop() {
        queue.sync {
            self.isStopped = true
            self.pendingWorkItem?.cancel()
            self.pendingWorkItem = nil
            self.reattachWorkItem?.cancel()
            self.reattachWorkItem = nil
            self.teardownSourceLocked()
        }
    }

    private func attachSourceLocked() throws {
        guard !isStopped else { return }

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            throw ProfileWatcherError.fileNotAccessible(fileURL.path, errno)
        }
        fileDescriptor = fd

        let eventMask: DispatchSource.FileSystemEvent = [.write, .extend, .rename, .delete, .attrib]
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: eventMask,
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            let flags = newSource.data
            self.scheduleDebouncedCallbackLocked()

            if flags.contains(.delete) || flags.contains(.rename) {
                self.teardownSourceLocked()
                self.scheduleReattachLocked(attempt: 0)
            }
        }

        newSource.setCancelHandler {
            close(fd)
        }

        source = newSource
        newSource.resume()
    }

    private func teardownSourceLocked() {
        if let existing = source {
            source = nil
            fileDescriptor = -1
            existing.cancel()
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func scheduleDebouncedCallbackLocked() {
        pendingWorkItem?.cancel()
        let callback = onChange
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            callback()
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func scheduleReattachLocked(attempt: Int) {
        guard !isStopped, attempt < 20 else { return }
        reattachWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            do {
                try self.attachSourceLocked()
            } catch {
                self.scheduleReattachLocked(attempt: attempt + 1)
            }
        }
        reattachWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
