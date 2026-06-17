import Foundation
import CoreServices

/// Watches a set of directories with FSEvents and fires a debounced callback on the
/// main queue. Watches both the agent dirs and the canonical store so edits to a
/// symlinked skill's real files (under `~/.agents/skills`) are caught too.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.zackbart.skillz.fswatch")
    private var debounceItem: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: () -> Void

    init(debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    func start(paths: [String]) {
        stop()
        let existing = Array(Set(paths.filter { FileManager.default.fileExists(atPath: $0) }))
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        // Publish + start on `queue` so `stream`/`debounceItem` are only ever touched from
        // the one thread the FSEvents callback and debounce also run on — no cross-thread race.
        queue.sync {
            self.stream = stream
            FSEventStreamStart(stream)
        }
    }

    private func schedule() {
        // Runs on `queue` (the FSEvents callback thread) — same queue as start/stop, so the
        // debounce item is single-threaded.
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    func stop() {
        // Tear down on `queue`: serial execution guarantees no callback/debounce is mid-flight,
        // cancelling stops a queued debounce from firing after teardown (a use-after-free if the
        // watcher is then released), and confining the state here removes the cross-thread race.
        queue.sync {
            debounceItem?.cancel()
            debounceItem = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
