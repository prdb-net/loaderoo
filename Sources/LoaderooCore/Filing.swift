import Foundation
import Darwin
import GRDB

private struct FileIdentity: Codable, Equatable {
    let device, inode, size: UInt64
    let modified: Date
    init(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, let date = values[.modificationDate] as? Date else {
            throw FeedError("Could not verify the video on disk.")
        }
        // Network shares can number their files by path, so that a rename changes the number.
        let numbered = (try? url.resourceValues(forKeys: [.volumeSupportsPersistentIDsKey]))?.volumeSupportsPersistentIDs ?? true
        self.device = device.uint64Value
        self.inode = numbered ? inode.uint64Value : 0
        self.size = size.uint64Value
        self.modified = date
    }

    /// The same file, also after the volume was mounted again under another device number.
    /// Shares and FAT volumes can round a timestamp once it has been set.
    static func == (a: Self, b: Self) -> Bool {
        a.inode == b.inode && a.size == b.size && abs(a.modified.timeIntervalSince(b.modified)) < 2
    }
}

/// `staged` is a copy or hard link beside the target, or the source itself when it only needs a rename.
private struct FilingPlan: Codable {
    let source, target, staged: URL
    let original, copy: FileIdentity
}

/// File-system steps that depend on the volume. Tests replace them to stand in for a network share.
struct FileMoves: Sendable {
    var link: @Sendable (_ source: URL, _ target: URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) }
    /// Renames without replacing an existing file. Returns 0 or `errno`.
    var renameExclusively: @Sendable (_ source: String, _ target: String) -> Int32 = {
        renamex_np($0, $1, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }
    var sameVolume: @Sendable (URL, URL) -> Bool = { a, b in
        let device = { (url: URL) in try? FileManager.default.attributesOfItem(atPath: url.path)[.systemNumber] as? NSNumber }
        return device(a) != nil && device(a) == device(b)
    }
}

/// Moves completed downloads into the library. It works on the database and the file system only,
/// so that it can run away from the `LiveFeed` actor.
struct Filer: Sendable {
    let store: DatabaseQueue
    let moves: FileMoves

    /// Runs `work` unless another filing pass holds the journal. Returns whether it ran.
    @discardableResult
    private func exclusively(_ work: () throws -> Void) throws -> Bool {
        let lock = open(store.path + ".filing-lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw FeedError("The filing journal could not be locked.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return false }
        try work()
        return true
    }

    func finish(_ item: Transfer, sab: SABConnection) throws {
        try exclusively {
            do { try file(item, sab: sab) }
            catch {
                try store.write { try $0.execute(sql: "UPDATE transfer SET state=?,note=? WHERE video=?",
                                                 arguments: [TransferState.awaitingFiling,error.localizedDescription,item.id]) }
            }
        }
    }

    /// Forgets a download together with its filing journal. The only file it removes is a staged copy
    /// whose original is still in place.
    func abandon(_ video: String) throws {
        let ran = try exclusively {
            let fm = FileManager.default
            let (partial, saved) = try store.read { db in
                (try String.fetchOne(db, sql: "SELECT path FROM staging WHERE video=?", arguments: [video]),
                 try Data.fetchOne(db, sql: "SELECT plan FROM filing WHERE video=?", arguments: [video]))
            }
            if let partial, fm.fileExists(atPath: partial) { try fm.removeItem(atPath: partial) }
            if let plan = try saved.map({ try JSONDecoder().decode(FilingPlan.self, from: $0) }), plan.staged != plan.source,
               fm.fileExists(atPath: plan.staged.path), fm.fileExists(atPath: plan.source.path) {
                try fm.removeItem(at: plan.staged)
            }
            try store.write { db in
                for table in ["transfer", "transferSource", "completedFile", "studioRetry", "staging", "filing"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE video=?", arguments: [video])
                }
            }
        }
        guard ran else { throw FeedError("Wait for the current filing to finish.") }
    }

    private func file(_ item: Transfer, sab: SABConnection) throws {
        let fm = FileManager.default
        guard try store.read({ try TransferState.fetchOne($0, sql: "SELECT state FROM transfer WHERE video=?", arguments: [item.id]) }) != .completed else { return }
        let unfinished = try store.read { try String.fetchOne($0, sql: "SELECT path FROM staging WHERE video=?", arguments: [item.id]) }
        if let unfinished {
            if fm.fileExists(atPath: unfinished) { try fm.removeItem(atPath: unfinished) }
            try store.write { try $0.execute(sql: "DELETE FROM staging WHERE video=?", arguments: [item.id]) }
        }
        let saved = try store.read { try Data.fetchOne($0, sql: "SELECT plan FROM filing WHERE video=?", arguments: [item.id]) }
        if let saved {
            try publish(try JSONDecoder().decode(FilingPlan.self, from: saved), item: item)
            return
        }
        guard let reported = item.storage, !sab.mount.isEmpty else {
            throw FeedError("Set the completed-folder mapping in Connections to locate this download.")
        }
        let source: URL
        if let local = item.localPath {
            source = URL(filePath: local)
            let identity = try FileIdentity(source)
            guard try store.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM completedFile WHERE video=? AND size=? AND modified=?)",
                arguments: [item.id,Int64(identity.size),identity.modified.timeIntervalSince1970]) }) == true else {
                throw FeedError("The previously filed video changed. Its file was preserved.")
            }
        } else { source = try LiveFeed.completedVideo(reported, sab: sab) }
        let needsStudio = item.studio?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        guard !sab.destination.isEmpty, !needsStudio || sab.unsortedFolder else {
            try complete(item, path: source)
            return
        }
        let root = URL(filePath: sab.destination).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FeedError("Waiting for the destination folder.")
        }
        let studio = needsStudio ? "Unsorted" : LiveFeed.component(item.studio!)
        let folder = root.appending(component: studio)
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == folder.standardizedFileURL.path else {
            throw FeedError("The studio folder resolves outside its expected location.")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = sab.originalName || needsStudio ? source.deletingPathExtension().lastPathComponent : LiveFeed.component(item.title)
        var target = folder.appending(component: stem).appendingPathExtension(source.pathExtension)
        if source.standardizedFileURL == target.standardizedFileURL { try complete(item, path: source); return }
        var suffix = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appending(component: "\(stem) (\(suffix))").appendingPathExtension(source.pathExtension)
            suffix += 1
        }
        let staged = folder.appending(component: ".loaderoo-\(UUID().uuidString).partial")
        let original = try FileIdentity(source)
        try store.write { try $0.execute(sql: "INSERT INTO staging VALUES(?,?)", arguments: [item.id,staged.path]) }
        let plan: FilingPlan
        do {
            // A hard link makes same-volume filing independent of video size.
            let linked = (try? moves.link(source, staged)) != nil
            if !linked, moves.sameVolume(source, folder) {
                // Shares have no hard links. The video still only needs a rename, which the plan records
                // before anything moves.
                plan = FilingPlan(source: source, target: target, staged: source, original: original, copy: original)
            } else {
                // Another volume needs a copy. It appears under its final name once it is complete.
                if !linked { try fm.copyItem(at: source, to: staged) }
                plan = FilingPlan(source: source, target: target, staged: staged, original: original, copy: try FileIdentity(staged))
            }
            guard plan.copy.size == original.size, try FileIdentity(source) == original else { throw FeedError("The source file changed during filing.") }
            try store.write {
                try $0.execute(sql: "INSERT INTO filing(video,plan) VALUES(?,?)", arguments: [item.id,try JSONEncoder().encode(plan)])
                try $0.execute(sql: "DELETE FROM staging WHERE video=?", arguments: [item.id])
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        try publish(plan, item: item)
    }

    private func publish(_ plan: FilingPlan, item: Transfer) throws {
        let fm = FileManager.default
        let moving = plan.staged == plan.source
        if fm.fileExists(atPath: plan.staged.path) {
            guard try FileIdentity(plan.staged) == plan.copy else {
                throw FeedError(moving ? "The original file changed. It was left in place." : "The staged copy changed.")
            }
            var failure = moves.renameExclusively(plan.staged.path, plan.target.path)
            if failure == ENOTSUP { failure = Self.renameAfterClaiming(plan.staged.path, plan.target.path) }
            guard failure == 0 else {
                if failure == EEXIST {
                    // A staged copy is expendable. A video that was to be renamed is the only one there is.
                    if !moving { try fm.removeItem(at: plan.staged) }
                    try store.write { try $0.execute(sql: "DELETE FROM filing WHERE video=?", arguments: [item.id]) }
                    throw FeedError("The destination name was taken. Filing will retry with a new name.")
                }
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
        }
        guard try FileIdentity(plan.target) == plan.copy else { throw FeedError("Waiting for the verified destination file.") }
        guard plan.target.resolvingSymlinksInPath().path == plan.target.path,
              plan.source.deletingLastPathComponent().resolvingSymlinksInPath().path == plan.source.deletingLastPathComponent().path else {
            throw FeedError("A filing folder changed. Both files have been preserved.")
        }
        if !moving, fm.fileExists(atPath: plan.source.path) {
            guard try FileIdentity(plan.source) == plan.original else { throw FeedError("The original file changed. Both files have been preserved.") }
            try fm.removeItem(at: plan.source)
        }
        try complete(item, path: plan.target)
    }

    /// For volumes without exclusive renaming, such as SMB and NFS shares: claims the name with an
    /// empty file, then renames over that claim. Returns 0 or `errno`.
    private static func renameAfterClaiming(_ source: String, _ target: String) -> Int32 {
        let claim = open(target, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        if claim >= 0 { close(claim) }
        else {
            let failure = errno
            // An empty file is the claim of an attempt that was interrupted before its rename.
            var existing = stat()
            guard failure == EEXIST, lstat(target, &existing) == 0,
                  existing.st_mode & S_IFMT == S_IFREG, existing.st_size == 0 else { return failure }
        }
        return rename(source, target) == 0 ? 0 : errno
    }

    private func complete(_ item: Transfer, path: URL) throws {
        let identity = try FileIdentity(path)
        try store.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO completedFile VALUES(?,?,?)",
                           arguments: [item.id,Int64(identity.size),identity.modified.timeIntervalSince1970])
            try $0.execute(sql: "UPDATE libraryFile SET video=?,title=?,studio=?,image=? WHERE path=? AND size=? AND modified=?",
                           arguments: [item.id,item.title,item.studio,item.image,path.path,Int64(identity.size),identity.modified.timeIntervalSince1970])
            try $0.execute(sql: "UPDATE transfer SET state=?,localPath=?,note=NULL WHERE video=?",
                           arguments: [TransferState.completed,path.path,item.id])
            try $0.execute(sql: "DELETE FROM filing WHERE video=?", arguments: [item.id])
        }
    }
}

extension LiveFeed {
    static func component(_ string: String) -> String {
        let parts = string.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
        var name = parts.joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.newlines))
        while name.utf8.count > 190 { name.removeLast() }
        return name.isEmpty ? "Untitled" : name
    }

    static func completedVideo(_ reported: String, sab: SABConnection) throws -> URL {
        let root = sab.remoteRoot.split(separator: "/")
        let path = reported.split(separator: "/")
        guard reported.hasPrefix("/"), path.starts(with: root), path.count > root.count,
              !path.contains(".."), !path.contains(".") else { throw FeedError("The completed job path does not match the container folder.") }
        let mount = URL(filePath: sab.mount).resolvingSymlinksInPath().standardizedFileURL
        let mapped = path.dropFirst(root.count).reduce(mount) { $0.appending(component: String($1)) }
        guard mapped.resolvingSymlinksInPath().path == mapped.path else { throw FeedError("The job path contains a symbolic link.") }
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]
        let attributes = try mapped.resourceValues(forKeys: keys)
        func movie(_ url: URL) throws -> Int? {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  LibraryScanner.extensions.contains(url.pathExtension.lowercased()) else { return nil }
            return values.fileSize ?? 0
        }
        if try movie(mapped) != nil { return mapped }
        var readable = true
        guard attributes.isDirectory == true, let files = FileManager.default.enumerator(at: mapped,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles,.skipsPackageDescendants],
                errorHandler: { _,_ in readable = false; return false }) else { throw FeedError("Waiting for the completed video on the Mac.") }
        var videos: [(url: URL, size: Int)] = []
        for case let url as URL in files {
            if let size = try movie(url) { videos.append((url, size)) }
        }
        guard readable, let largest = videos.map(\.size).max() else { throw FeedError("Waiting for one readable video in the completed folder.") }
        // A sample or trailer rides along with the release: it is far smaller, or named as a sample.
        let features = videos.filter { video in
            let inside = video.url.path.dropFirst(mapped.path.count)
            return video.size == largest || video.size * 10 >= largest && !inside.localizedCaseInsensitiveContains("sample")
        }
        guard features.count == 1 else { throw FeedError("The completed folder contains multiple videos. Files were left in place.") }
        return features[0].url.resolvingSymlinksInPath()
    }
}
