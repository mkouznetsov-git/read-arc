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
    if call.method == "refreshRoot" {
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let value = try self.refreshRoot(call.arguments as? [String: Any] ?? [:])
          DispatchQueue.main.async { result(value) }
        } catch IOSLibraryError.permissionLost {
          DispatchQueue.main.async { result(FlutterError(code: "permissionLost", message: "Library permission was lost", details: nil)) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "temporarilyUnavailable", message: error.localizedDescription, details: nil)) }
        }
      }
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
        case "readServiceFile": value = try self.readServiceFile(root, arguments)
        case "listServiceFiles": value = try self.listServiceFiles(root, arguments)
        case "publishServiceFile":
          try self.publishServiceFile(root, arguments); value = nil
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

  private func refreshRoot(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let root = arguments["root"] as? [String: Any],
          let encoded = root["locator"] as? String,
          let data = Data(base64Encoded: encoded) else { throw IOSLibraryError.invalidArguments }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
    guard url.startAccessingSecurityScopedResource() else { throw IOSLibraryError.permissionLost }
    defer { url.stopAccessingSecurityScopedResource() }
    if !stale { return root }
    let refreshed = try url.bookmarkData(
      options: [.minimalBookmark],
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
    return [
      "kind": "appleSecurityScopedBookmark",
      "locator": refreshed.base64EncodedString(),
      "displayName": root["displayName"] as? String ?? url.lastPathComponent,
    ]
  }

  private func entryURL(_ root: URL, _ arguments: [String: Any]) throws -> URL {
    guard let relative = arguments["relativeLocation"] as? String else { throw IOSLibraryError.invalidArguments }
    let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.isEmpty,
          !relative.hasPrefix("/"),
          !relative.contains("\0"),
          !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { throw IOSLibraryError.invalidArguments }
    let candidate = root.appendingPathComponent(relative).standardizedFileURL
    guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw IOSLibraryError.invalidArguments }
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard candidate.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else {
      throw IOSLibraryError.invalidArguments
    }
    return candidate
  }

  private func listEntries(_ root: URL) throws -> [[String: Any?]] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
      throw IOSLibraryError.missing
    }
    let prefixLength = root.standardizedFileURL.path.count + 1
    var entries: [[String: Any?]] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let relative = String(url.standardizedFileURL.path.dropFirst(prefixLength))
      let needsDownload = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
      entries.append([
        "relativeLocation": relative,
        "sizeBytes": values.fileSize ?? 0,
        "modifiedAt": values.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) },
        "availability": needsDownload ? "requiresMaterialization" : "available",
      ])
    }
    return entries.sorted { ($0["relativeLocation"] as? String ?? "") < ($1["relativeLocation"] as? String ?? "") }
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
    if (try source.resourceValues(forKeys: [.isUbiquitousItemKey])).isUbiquitousItem == true {
      try FileManager.default.startDownloadingUbiquitousItem(at: source)
    }
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
    let resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let sourceValues = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
    let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
    if sourceValues.isSymbolicLink != true, resolvedSource.path.hasPrefix(resolvedRootPath) {
      return String(resolvedSource.path.dropFirst(resolvedRootPath.count))
    }
    let name = (preferredName as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    var candidate = name
    var suffix = 2
    while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
      candidate = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
      suffix += 1
    }
    let destination = root.appendingPathComponent(candidate)
    let staged = root.appendingPathComponent(".\(candidate).readarc-partial-\(UUID().uuidString)")
    do {
      try FileManager.default.copyItem(at: source, to: staged)
      guard try sha256(source) == sha256(staged) else { throw IOSLibraryError.verificationFailed }
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw IOSLibraryError.destinationCollision
      }
      try FileManager.default.moveItem(at: staged, to: destination)
      guard try sha256(destination) == sha256(source) else {
        try? FileManager.default.removeItem(at: destination)
        throw IOSLibraryError.verificationFailed
      }
      return candidate
    } catch {
      try? FileManager.default.removeItem(at: staged)
      throw error
    }
  }
  private func serviceURL(_ root: URL, _ arguments: [String: Any]) throws -> URL {
    let url = try entryURL(root, arguments)
    let relative = arguments["relativeLocation"] as? String ?? ""
    guard relative == ".readarc" || relative.hasPrefix(".readarc/") else {
      throw IOSLibraryError.invalidArguments
    }
    return url
  }

  private func readServiceFile(_ root: URL, _ arguments: [String: Any]) throws -> FlutterStandardTypedData? {
    let source = try serviceURL(root, arguments)
    guard FileManager.default.fileExists(atPath: source.path) else { return nil }
    var coordinatorError: NSError?
    var readError: Error?
    var data: Data?
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { coordinated in
      do { data = try Data(contentsOf: coordinated) } catch { readError = error }
    }
    if let error = coordinatorError { throw error }
    if let error = readError { throw error }
    return data.map(FlutterStandardTypedData.init(bytes:))
  }

  private func listServiceFiles(_ root: URL, _ arguments: [String: Any]) throws -> [String] {
    let directory = try serviceURL(root, arguments)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: keys,
      options: [.skipsPackageDescendants])
    else { return [] }
    let prefixLength = root.standardizedFileURL.path.count + 1
    var result: [String] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let standardized = url.standardizedFileURL.path
      guard standardized.hasPrefix(root.standardizedFileURL.path + "/") else {
        throw IOSLibraryError.invalidArguments
      }
      result.append(String(standardized.dropFirst(prefixLength)))
    }
    return result.sorted()
  }

  private func publishServiceFile(_ root: URL, _ arguments: [String: Any]) throws {
    guard FileManager.default.fileExists(atPath: root.path) else {
      throw IOSLibraryError.missing
    }
    let target = try serviceURL(root, arguments)
    guard let typed = arguments["bytes"] as? FlutterStandardTypedData else {
      throw IOSLibraryError.invalidArguments
    }
    let preservePrevious = arguments["preservePrevious"] as? Bool ?? true
    let data = typed.data
    let parent = target.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true)
    let staged = parent.appendingPathComponent(
      "." + target.lastPathComponent + ".readarc-staging-" + UUID().uuidString)
    let previous = parent.appendingPathComponent("previous")
    var movedCurrent = false
    var published = false
    do {
      try data.write(to: staged, options: [.withoutOverwriting])
      let handle = try FileHandle(forWritingTo: staged)
      try handle.synchronize()
      try handle.close()
      guard try Data(contentsOf: staged) == data else {
        throw IOSLibraryError.verificationFailed
      }
      var coordinatorError: NSError?
      var publishError: Error?
      NSFileCoordinator().coordinate(
        writingItemAt: parent,
        options: .forMerging,
        error: &coordinatorError
      ) { _ in
        do {
          if preservePrevious && FileManager.default.fileExists(atPath: previous.path) {
            try FileManager.default.removeItem(at: previous)
          }
          if preservePrevious && FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: target, to: previous)
            movedCurrent = true
          } else if !preservePrevious && FileManager.default.fileExists(atPath: target.path) {
            throw IOSLibraryError.destinationCollision
          }
          try FileManager.default.moveItem(at: staged, to: target)
          published = true
        } catch {
          publishError = error
        }
      }
      if let error = coordinatorError { throw error }
      if let error = publishError { throw error }
      guard try Data(contentsOf: target) == data else {
        throw IOSLibraryError.verificationFailed
      }
    } catch {
      if published { try? FileManager.default.removeItem(at: target) }
      if movedCurrent { try? FileManager.default.moveItem(at: previous, to: target) }
      try? FileManager.default.removeItem(at: staged)
      throw error
    }
  }


}

private enum IOSLibraryError: Error {
  case invalidArguments
  case staleBookmark
  case permissionLost
  case missing
  case unsupported
  case verificationFailed
  case destinationCollision
}
