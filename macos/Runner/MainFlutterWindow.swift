import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The same channel and method Android's MainActivity answers, so the Dart
    // side has one path: the copy is taken here and only its path crosses.
    // Nothing else on this channel is asked for on a Mac — `saveAs`,
    // `copyImage`, `open` and `shared` are Android's, and guarded there.
    let share = FlutterMethodChannel(
      name: "sshbox/share",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    share.setMethodCallHandler { call, result in
      guard call.method == "clipboardImage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      ClipboardImage.take(
        limit: (call.arguments as? NSNumber)?.intValue ?? 0, result: result)
    }

    super.awakeFromNib()
  }
}

/// The picture on the Mac's clipboard, copied into a file of the app's own:
/// a path and a name, the shape Android hands back, or nothing at all when
/// the clipboard holds no picture — then the paste goes on to be text.
///
/// A terminal is a byte stream, so a picture can only reach the host as a
/// file the upload puts there; that is why the bytes stop here and only the
/// path is answered.
enum ClipboardImage {
  /// One image at a time, as Android keeps one: the directory is emptied
  /// before each copy, so a paste leaves no pile of pictures behind.
  private static var directory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("clipboard", isDirectory: true)
  }

  /// What a picture that cannot be taken says. There is no app to name on a
  /// Mac — the pasteboard does not say who wrote it — so it says what to do.
  private static let refused =
    "The picture on the clipboard could not be read. Try copying it again, "
    + "or open it from the files drawer."

  static func take(limit: Int, result: @escaping FlutterResult) {
    let board = NSPasteboard.general

    // A picture copied in Finder arrives as a file URL, and is taken as it
    // is, name and all. Everything else — a screenshot, a copy from a
    // browser — arrives as bytes, and macOS offers the same picture under
    // several types: PNG first, being lossless and small; then JPEG, which
    // is a photo's own bytes; TIFF last, which macOS synthesises for almost
    // anything and which is far the largest.
    if let url = fileURL(board) {
      copy(from: url, limit: limit, result: result)
      return
    }
    let types: [NSPasteboard.PasteboardType] = [
      .png, NSPasteboard.PasteboardType("public.jpeg"), .tiff,
    ]
    guard let type = types.first(where: { board.availableType(from: [$0]) != nil }) else {
      result(nil)
      return
    }
    // It said it had one: a type that then hands over nothing is an error,
    // never silence, which reads as a feature that does nothing.
    guard let data = board.data(forType: type) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    if data.count > limit {
      result(FlutterError(code: "too_big", message: tooBig(limit), details: nil))
      return
    }
    let name = stamped(extension: self.extension(of: type))
    guard let file = write(data, as: name) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    result(["path": file.path, "name": name])
  }

  /// The clipboard's file URL, when it is a picture this app can send: a
  /// folder, a PDF or a video copied in Finder is not, and the paste goes on
  /// to be text as it would with nothing on the clipboard.
  private static func fileURL(_ board: NSPasteboard) -> URL? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    guard
      let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
      let url = urls.first,
      let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
      type.conforms(to: .image)
    else { return nil }
    return url
  }

  /// A picture already on disk: weighed before it is copied, so a huge one
  /// is refused without being read at all, and keeping the name it has.
  private static func copy(from url: URL, limit: Int, result: @escaping FlutterResult) {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size > limit {
      result(FlutterError(code: "too_big", message: tooBig(limit), details: nil))
      return
    }
    guard let data = try? Data(contentsOf: url) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    let name = url.lastPathComponent
    guard let file = write(data, as: name) else {
      result(FlutterError(code: "unreadable", message: refused, details: nil))
      return
    }
    result(["path": file.path, "name": name])
  }

  /// [data] in [directory] under [name], the directory emptied first.
  private static func write(_ data: Data, as name: String) -> URL? {
    let manager = FileManager.default
    try? manager.removeItem(at: directory)
    guard
      (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
    else { return nil }
    let file = directory.appendingPathComponent(name)
    guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
    return file
  }

  /// What a picture with no name of its own is called once it is on the
  /// host, where the user reads it and types it at a prompt — as Android
  /// names one the clipboard gave no name worth keeping.
  private static func stamped(extension suffix: String) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyyMMdd-HHmmss"
    return "pasted-\(format.string(from: Date())).\(suffix)"
  }

  private static func `extension`(of type: NSPasteboard.PasteboardType) -> String {
    switch type {
    case .png: return "png"
    case .tiff: return "tiff"
    default: return "jpg"
    }
  }

  private static func tooBig(_ limit: Int) -> String {
    "That image is bigger than \(limit / (1024 * 1024)) MB — send it from "
      + "the files drawer instead."
  }
}
