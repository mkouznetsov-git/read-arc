import Cocoa
import CryptoKit
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let libraryChannel = FlutterMethodChannel(
      name: "readarc/library_storage",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    libraryChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleLibraryCall(call, result: result)
    }

    super.awakeFromNib()
  }

  private func handleLibraryCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "chooseRoot" {
      chooseRoot(result: result)
      return
    }
    if call.method == "refreshRoot" {
      perform(result: result) {
        try self.refreshRoot(call.arguments as? [String: Any] ?? [:])
      }
      return
    }
    perform(result: result) {
      let arguments = call.arguments as? [String: Any] ?? [:]
      let root = try self.resolveRoot(arguments)
      defer { root.stopAccessingSecurityScopedResource() }
      switch call.method {
      case "status":
        return FileManager.default.fileExists(atPath: root.path) ? "available" : "missing"
      case "listEntries":
        return try self.listEntries(root)
      case "contentSha256":
        return try self.sha256(self.entryURL(root, arguments))
      case "materialize":
        return try self.materialize(self.entryURL(root, arguments), targetPath: arguments["targetPath"] as! String)
      case "importFile":
        return try self.importFile(
          root,
          sourcePath: arguments["sourcePath"] as! String,
          preferredName: arguments["preferredName"] as! String)
      case "deleteEntry":
        try FileManager.default.removeItem(at: self.entryURL(root, arguments))
        return nil
      case "containsFile":
        let source = URL(fileURLWithPath: arguments["sourcePath"] as! String).standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        return source.hasPrefix(prefix)
      case "readServiceFile":
        return try self.readServiceFile(root, arguments)
      case "listServiceFiles":
        return try self.listServiceFiles(root, arguments)
      case "publishServiceFile":
        try self.publishServiceFile(root, arguments)
        return nil
      default:
        throw LibraryStorageError.unsupported
      }
    }
  }

  private func chooseRoot(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "Выберите библиотеку ReadArc"
    panel.prompt = "Выбрать"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      do {
        let bookmark = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result([
          "kind": "appleSecurityScopedBookmark",
          "locator": bookmark.base64EncodedString(),
          "displayName": url.lastPathComponent,
        ])
      } catch {
        result(FlutterError(code: "permissionLost", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func perform(result: @escaping FlutterResult, operation: @escaping () throws -> Any?) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try operation()
        DispatchQueue.main.async { result(value) }
      } catch LibraryStorageError.staleBookmark {
        DispatchQueue.main.async {
          result(FlutterError(code: "permissionLost", message: "Security-scoped bookmark is stale", details: nil))
        }
      } catch LibraryStorageError.permissionLost {
        DispatchQueue.main.async {
          result(FlutterError(code: "permissionLost", message: "Library permission was lost", details: nil))
        }
      } catch LibraryStorageError.missing {
        DispatchQueue.main.async {
          result(FlutterError(code: "missing", message: "Library root is missing", details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "temporarilyUnavailable", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func resolveRoot(_ arguments: [String: Any]) throws -> URL {
    guard
      let root = arguments["root"] as? [String: Any],
      let encoded = root["locator"] as? String,
      let data = Data(base64Encoded: encoded)
    else { throw LibraryStorageError.invalidArguments }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
    if stale { throw LibraryStorageError.staleBookmark }
    guard url.startAccessingSecurityScopedResource() else { throw LibraryStorageError.permissionLost }
    return url
  }

  private func refreshRoot(_ arguments: [String: Any]) throws -> [String: Any] {
    guard
      let root = arguments["root"] as? [String: Any],
      let encoded = root["locator"] as? String,
      let data = Data(base64Encoded: encoded)
    else { throw LibraryStorageError.invalidArguments }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
    guard url.startAccessingSecurityScopedResource() else { throw LibraryStorageError.permissionLost }
    defer { url.stopAccessingSecurityScopedResource() }
    if !stale { return root }
    let refreshed = try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
    return [
      "kind": "appleSecurityScopedBookmark",
      "locator": refreshed.base64EncodedString(),
      "displayName": root["displayName"] as? String ?? url.lastPathComponent,
    ]
  }

  private func entryURL(_ root: URL, _ arguments: [String: Any]) throws -> URL {
    guard let relative = arguments["relativeLocation"] as? String else {
      throw LibraryStorageError.invalidArguments
    }
    let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.isEmpty,
          !relative.hasPrefix("/"),
          !relative.contains("\0"),
          !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { throw LibraryStorageError.invalidArguments }
    let candidate = root.appendingPathComponent(relative).standardizedFileURL
    guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else {
      throw LibraryStorageError.invalidArguments
    }
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard candidate.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else {
      throw LibraryStorageError.invalidArguments
    }
    return candidate
  }

  private func listEntries(_ root: URL) throws -> [[String: Any?]] {
    let keys: [URLResourceKey] = [
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
      .contentModificationDateKey,
      .isUbiquitousItemKey,
      .ubiquitousItemDownloadingStatusKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { throw LibraryStorageError.missing }
    let prefixLength = root.standardizedFileURL.path.count + 1
    var entries: [[String: Any?]] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let standardized = url.standardizedFileURL.path
      guard standardized.count >= prefixLength else { continue }
      let relative = String(standardized.dropFirst(prefixLength))
      let needsMaterialization = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
      entries.append([
        "relativeLocation": relative,
        "sizeBytes": values.fileSize ?? 0,
        "modifiedAt": values.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) },
        "availability": needsMaterialization ? "requiresMaterialization" : "available",
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
    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
      do { try FileManager.default.copyItem(at: coordinated, to: target) } catch { copyError = error }
    }
    if let error = coordinationError { throw error }
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
      guard try sha256(source) == sha256(staged) else {
        throw LibraryStorageError.verificationFailed
      }
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw LibraryStorageError.destinationCollision
      }
      try FileManager.default.moveItem(at: staged, to: destination)
      guard try sha256(destination) == sha256(source) else {
        try? FileManager.default.removeItem(at: destination)
        throw LibraryStorageError.verificationFailed
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
      throw LibraryStorageError.invalidArguments
    }
    return url
  }

  private func readServiceFile(_ root: URL, _ arguments: [String: Any]) throws -> FlutterStandardTypedData? {
    let source = try serviceURL(root, arguments)
    guard FileManager.default.fileExists(atPath: source.path) else { return nil }
    var coordinationError: NSError?
    var readError: Error?
    var data: Data?
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
      do { data = try Data(contentsOf: coordinated) } catch { readError = error }
    }
    if let error = coordinationError { throw error }
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
        throw LibraryStorageError.invalidArguments
      }
      result.append(String(standardized.dropFirst(prefixLength)))
    }
    return result.sorted()
  }

  private func publishServiceFile(_ root: URL, _ arguments: [String: Any]) throws {
    guard FileManager.default.fileExists(atPath: root.path) else {
      throw LibraryStorageError.missing
    }
    let target = try serviceURL(root, arguments)
    guard let typed = arguments["bytes"] as? FlutterStandardTypedData else {
      throw LibraryStorageError.invalidArguments
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
        throw LibraryStorageError.verificationFailed
      }
      var coordinationError: NSError?
      var publishError: Error?
      NSFileCoordinator().coordinate(
        writingItemAt: parent,
        options: .forMerging,
        error: &coordinationError
      ) { _ in
        do {
          if preservePrevious && FileManager.default.fileExists(atPath: previous.path) {
            try FileManager.default.removeItem(at: previous)
          }
          if preservePrevious && FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: target, to: previous)
            movedCurrent = true
          } else if !preservePrevious && FileManager.default.fileExists(atPath: target.path) {
            throw LibraryStorageError.destinationCollision
          }
          try FileManager.default.moveItem(at: staged, to: target)
          published = true
        } catch {
          publishError = error
        }
      }
      if let error = coordinationError { throw error }
      if let error = publishError { throw error }
      guard try Data(contentsOf: target) == data else {
        throw LibraryStorageError.verificationFailed
      }
    } catch {
      if published { try? FileManager.default.removeItem(at: target) }
      if movedCurrent { try? FileManager.default.moveItem(at: previous, to: target) }
      try? FileManager.default.removeItem(at: staged)
      throw error
    }
  }


}

private enum LibraryStorageError: Error {
  case invalidArguments
  case staleBookmark
  case permissionLost
  case missing
  case unsupported
  case verificationFailed
  case destinationCollision
}
