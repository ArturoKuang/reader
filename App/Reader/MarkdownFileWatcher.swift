import Foundation
import ReaderCore

/// Watches one file through its parent directory and its own descriptor, so an atomic
/// save (write a temporary file, then rename over the original) is still seen.
final class MarkdownFileWatcher {
    private let url: URL
    private let onReload: (Data) -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileInode: UInt64?
    private var pending: DispatchWorkItem?
    private var fingerprint: String

    init(url: URL, initial: Data, onReload: @escaping (Data) -> Void) {
        self.url = url.resolvingSymlinksInPath()
        self.onReload = onReload
        fingerprint = SHA256.fingerprint(initial)
        directorySource = source(path: self.url.deletingLastPathComponent().path)
        watchFile()
        // Catches a save that landed between reading the document and watching it.
        schedule()
    }

    deinit { stop() }

    func stop() {
        pending?.cancel()
        pending = nil
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        fileInode = nil
    }

    private func source(path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Follows the file to its new inode after a rename replaced it.
    private func watchFile() {
        let inode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
        guard inode != fileInode || fileSource == nil else { return }
        fileSource?.cancel()
        fileSource = inode == nil ? nil : source(path: url.path)
        fileInode = inode
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func check() {
        watchFile()
        // A missing file is mid-rename; the directory event for its return reschedules.
        guard let data = try? Data(contentsOf: url) else { return }
        let next = SHA256.fingerprint(data)
        guard next != fingerprint else { return }
        fingerprint = next
        onReload(data)
    }
}
