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
        self.device = device.uint64Value
        self.inode = inode.uint64Value
        self.size = size.uint64Value
        self.modified = date
    }
}

private struct FilingPlan: Codable {
    let source, target, staged: URL
    let original, copy: FileIdentity
}

extension LiveFeed {
    func finish(_ item: Transfer, sab: SABConnection) throws {
        let lock = open(store.path + ".filing-lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw FeedError("The filing journal could not be locked.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        do {
            guard try store.read({ try String.fetchOne($0, sql: "SELECT state FROM transfer WHERE video=?", arguments: [item.id]) }) != "Completed" else { return }
            let unfinished = try store.read { try String.fetchOne($0, sql: "SELECT path FROM staging WHERE video=?", arguments: [item.id]) }
            if let unfinished {
                if FileManager.default.fileExists(atPath: unfinished) { try FileManager.default.removeItem(atPath: unfinished) }
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
            } else { source = try Self.completedVideo(reported, sab: sab) }
            let needsStudio = item.studio?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            guard !sab.destination.isEmpty, !needsStudio || sab.unsortedFolder else {
                try complete(item, path: source)
                return
            }
            let root = URL(filePath: sab.destination).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FeedError("Waiting for the destination folder.")
            }
            let studio = needsStudio ? "Unsorted" : Self.component(item.studio!)
            let folder = root.appending(component: studio)
            guard folder.resolvingSymlinksInPath().standardizedFileURL.path == folder.standardizedFileURL.path else {
                throw FeedError("The studio folder resolves outside its expected location.")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stem = sab.originalName || needsStudio ? source.deletingPathExtension().lastPathComponent : Self.component(item.title)
            var target = folder.appending(component: stem).appendingPathExtension(source.pathExtension)
            if source.standardizedFileURL == target.standardizedFileURL { try complete(item, path: source); return }
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appending(component: "\(stem) (\(suffix))").appendingPathExtension(source.pathExtension)
                suffix += 1
            }
            let staged = folder.appending(component: ".loaderoo-\(UUID().uuidString).partial")
            let original = try FileIdentity(source)
            try store.write { try $0.execute(sql: "INSERT INTO staging VALUES(?,?)", arguments: [item.id,staged.path]) }
            let plan: FilingPlan
            do {
                // A hard link makes same-volume filing independent of video size.
                // The staged copy also supports shares and cross-volume destinations.
                do { try FileManager.default.linkItem(at: source, to: staged) }
                catch { try FileManager.default.copyItem(at: source, to: staged) }
                let copy = try FileIdentity(staged)
                guard copy.size == original.size, try FileIdentity(source) == original else { throw FeedError("The source file changed during filing.") }
                plan = FilingPlan(source: source, target: target, staged: staged, original: original, copy: copy)
                try store.write {
                    try $0.execute(sql: "INSERT INTO filing(video,plan) VALUES(?,?)", arguments: [item.id,try JSONEncoder().encode(plan)])
                    try $0.execute(sql: "DELETE FROM staging WHERE video=?", arguments: [item.id])
                }
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
            try publish(plan, item: item)
        } catch {
            try store.write { try $0.execute(sql: "UPDATE transfer SET state='Awaiting filing',note=? WHERE video=?",
                                             arguments: [error.localizedDescription,item.id]) }
        }
    }

    private func publish(_ plan: FilingPlan, item: Transfer) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: plan.staged.path) {
            guard try FileIdentity(plan.staged) == plan.copy else { throw FeedError("The staged copy changed.") }
            guard renamex_np(plan.staged.path, plan.target.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST {
                    try fm.removeItem(at: plan.staged)
                    try store.write { try $0.execute(sql: "DELETE FROM filing WHERE video=?", arguments: [item.id]) }
                    throw FeedError("The destination name was taken. Filing will retry with a new name.")
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard try FileIdentity(plan.target) == plan.copy else { throw FeedError("Waiting for the verified destination file.") }
        guard plan.target.resolvingSymlinksInPath().path == plan.target.path,
              plan.source.deletingLastPathComponent().resolvingSymlinksInPath().path == plan.source.deletingLastPathComponent().path else {
            throw FeedError("A filing folder changed. Both files have been preserved.")
        }
        if fm.fileExists(atPath: plan.source.path) {
            guard try FileIdentity(plan.source) == plan.original else { throw FeedError("The original file changed. Both files have been preserved.") }
            try fm.removeItem(at: plan.source)
        }
        try complete(item, path: plan.target)
    }

    private func complete(_ item: Transfer, path: URL) throws {
        let identity = try FileIdentity(path)
        try store.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO completedFile VALUES(?,?,?)",
                           arguments: [item.id,Int64(identity.size),identity.modified.timeIntervalSince1970])
            try $0.execute(sql: "UPDATE libraryFile SET video=?,title=?,studio=?,image=? WHERE path=? AND size=? AND modified=?",
                           arguments: [item.id,item.title,item.studio,item.image,path.path,Int64(identity.size),identity.modified.timeIntervalSince1970])
            try $0.execute(sql: "UPDATE transfer SET state='Completed',localPath=?,note=NULL WHERE video=?", arguments: [path.path,item.id])
            try $0.execute(sql: "DELETE FROM filing WHERE video=?", arguments: [item.id])
        }
    }

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
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]
        let attributes = try mapped.resourceValues(forKeys: keys)
        func movie(_ url: URL) throws -> Bool {
            let values = try url.resourceValues(forKeys: keys)
            return values.isSymbolicLink != true && values.isRegularFile == true && LibraryScanner.extensions.contains(url.pathExtension.lowercased())
        }
        if try movie(mapped) { return mapped }
        var readable = true
        guard attributes.isDirectory == true, let files = FileManager.default.enumerator(at: mapped,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles,.skipsPackageDescendants],
                errorHandler: { _,_ in readable = false; return false }) else { throw FeedError("Waiting for the completed video on the Mac.") }
        var selected: URL?
        for case let url as URL in files {
            if try movie(url) {
                guard selected == nil else { throw FeedError("The completed folder contains multiple videos. Files were left in place.") }
                selected = url
            }
        }
        guard readable, let selected else { throw FeedError("Waiting for one readable video in the completed folder.") }
        return selected.resolvingSymlinksInPath()
    }
}
