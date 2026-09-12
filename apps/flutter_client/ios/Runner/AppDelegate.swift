import Flutter
import CryptoKit
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var libraryStoragePlugin: IOSLibraryStoragePlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    libraryStoragePlugin = IOSLibraryStoragePlugin(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

private final class IOSLibraryStoragePlugin: NSObject, UIDocumentPickerDelegate {
  private var pickerResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "readarc/library_storage", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "chooseRoot" {
      guard pickerResult == nil else {
        result(FlutterError(code: "busy", message: "Library picker is already open", details: nil))
        return
      }
      pickerResult = result
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
      picker.delegate = self
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)?
        .rootViewController?
        .present(picker, animated: true)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let root = try self.resolveRoot(arguments)
        defer { root.stopAccessingSecurityScopedResource() }
        let value: Any?
        switch call.method {
        case "status": value = FileManager.default.fileExists(atPath: root.path) ? "available" : "missing"
        case "listEntries": value = try self.listEntries(root)
        case "contentSha256": value = try self.sha256(self.entryURL(root, arguments))
        case "materialize":
          value = try self.materialize(self.entryURL(root, arguments), targetPath: arguments["targetPath"] as! String)
        case "importFile":
          value = try self.importFile(root, sourcePath: arguments["sourcePath"] as! String, preferredName: arguments["preferredName"] as! String)
        case "deleteEntry":
          try FileManager.default.removeItem(at: self.entryURL(root, arguments)); value = nil
        case "containsFile":
          let source = URL(fileURLWithPath: arguments["sourcePath"] as! String).standardizedFileURL.path
          value = source.hasPrefix(root.standardizedFileURL.path + "/")
        default: throw IOSLibraryError.unsupported
        }
        DispatchQueue.main.async { result(value) }
      } catch IOSLibraryError.staleBookmark {
        DispatchQueue.main.async { result(FlutterError(code: "permissionLost", message: "Library bookmark is stale", details: nil)) }
      } catch IOSLibraryError.permissionLost {
        DispatchQueue.main.async { result(FlutterError(code: "permissionLost", message: "Library permission was lost", details: nil)) }
      } catch IOSLibraryError.missing {
        DispatchQueue.main.async { result(FlutterError(code: "missing", message: "Library root is missing", details: nil)) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "temporarilyUnavailable", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    defer { pickerResult = nil }
    guard let url = urls.first else { pickerResult?(nil); return }
    do {
      let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
      pickerResult?([
        "kind": "appleSecurityScopedBookmark",
        "locator": bookmark.base64EncodedString(),
        "displayName": url.lastPathComponent,
      ])
    } catch {
      pickerResult?(FlutterError(code: "permissionLost", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pickerResult?(nil)
    pickerResult = nil
  }

  private func resolveRoot(_ arguments: [String: Any]) throws -> URL {
    guard let root = arguments["root"] as? [String: Any],
          let encoded = root["locator"] as? String,
          let data = Data(base64Encoded: encoded) else { throw IOSLibraryError.invalidArguments }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    if stale { throw IOSLibraryError.staleBookmark }
    guard url.startAccessingSecurityScopedResource() else { throw IOSLibraryError.permissionLost }
    return url
  }

  private func entryURL(_ root: URL, _ arguments: [String: Any]) throws -> URL {
    guard let relative = arguments["relativeLocation"] as? String else { throw IOSLibraryError.invalidArguments }
    let candidate = root.appendingPathComponent(relative).standardizedFileURL
    guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw IOSLibraryError.invalidArguments }
    return candidate
  }

  private func listEntries(_ root: URL) throws -> [[String: Any?]] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
      throw IOSLibraryError.missing
    }
    let prefixLength = root.standardizedFileURL.path.count + 1
    var entries: [[String: Any?]] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }
      let relative = String(url.standardizedFileURL.path.dropFirst(prefixLength)).replacingOccurrences(of: "\\", with: "/")
      let needsDownload = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
      entries.append([
        "relativeLocation": relative,
        "sizeBytes": values.fileSize ?? 0,
        "modifiedAt": values.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) },
        "availability": needsDownload ? "requiresMaterialization" : "available",
      ])
    }
    return entries
  }

  private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while true {
      let data = try handle.read(upToCount: 256 * 1024) ?? Data()
      if data.isEmpty { break }
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func materialize(_ source: URL, targetPath: String) throws -> String {
    let target = URL(fileURLWithPath: targetPath)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    var coordinatorError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { coordinated in
      do { try FileManager.default.copyItem(at: coordinated, to: target) } catch { copyError = error }
    }
    if let error = coordinatorError { throw error }
    if let error = copyError { throw error }
    return target.path
  }

  private func importFile(_ root: URL, sourcePath: String, preferredName: String) throws -> String {
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let prefix = root.standardizedFileURL.path + "/"
    if source.path.hasPrefix(prefix) { return String(source.path.dropFirst(prefix.count)) }
    let name = (preferredName as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    var candidate = name
    var suffix = 2
    while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
      candidate = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
      suffix += 1
    }
    try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(candidate))
    return candidate
  }
}

private enum IOSLibraryError: Error {
  case invalidArguments
  case staleBookmark
  case permissionLost
  case missing
  case unsupported
}
