import Foundation

/// Watches the directory containing a file (builds usually replace files rather than write in
/// place) and calls `onChange` on the main queue, debounced, when that directory changes.
final class FileWatcher {
  private let source: DispatchSourceFileSystemObject
  private var pending: DispatchWorkItem?

  init?(path: String, debounce: DispatchTimeInterval = .milliseconds(50), onChange: @escaping () -> Void) {
    let dir = (path as NSString).deletingLastPathComponent
    let fd = open(dir.isEmpty ? "." : dir, O_EVTONLY)
    guard fd >= 0 else { return nil }
    source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      self.pending?.cancel()
      let item = DispatchWorkItem(block: onChange)
      self.pending = item
      DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
  }

  func cancel() {
    pending?.cancel()
    source.cancel()
  }
}
