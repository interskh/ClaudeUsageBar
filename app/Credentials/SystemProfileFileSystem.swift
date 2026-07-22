import Foundation

// The real filesystem behind `ProfileFileSystem`. APP-ONLY, excluded from the test
// target by name in build.sh for the same reason `KeychainStore` is: it reads the
// developer's actual home directory and environment, so a test that reached it would
// pass or fail depending on whose machine it ran on. Tests inject a fake instead.
struct SystemProfileFileSystem: ProfileFileSystem {
    // A profile config is a few hundred KB in practice (477 KB for the largest on the
    // target machine). The cap exists so a pathological or corrupt file cannot be
    // pulled into memory wholesale on a discovery pass that runs every popover open;
    // it is generous enough that a legitimate file never trips it, and exceeding it is
    // logged rather than passed silently as "no config".
    static let maximumIdentityFileBytes = 8 * 1024 * 1024

    private let fileManager = FileManager.default

    var homeDirectoryPath: String {
        NSHomeDirectory()
    }

    func environmentVariable(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }

    func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    func directoryEntries(atPath path: String) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
    }

    // The three-way read (§4.1's `failed`-vs-`signedOut` split, applied to files). The
    // default implementation of this method cannot tell "not there" from "there and
    // unreadable" because `fileContents` returns nil for both; this conformer can, and
    // the distinction is the difference between telling a user they are signed out and
    // telling them the app could not read their credential.
    func readFile(atPath path: String) -> FileReadResult {
        guard fileManager.fileExists(atPath: path) else { return .missing }
        // Size is checked BEFORE reading, not after: reading then rejecting would have
        // already done the damage the cap exists to prevent.
        if let size = (try? fileManager.attributesOfItem(atPath: path)[.size]) as? NSNumber,
           size.intValue > SystemProfileFileSystem.maximumIdentityFileBytes {
            return .unreadable("the file is larger than this app will read")
        }
        guard let data = fileManager.contents(atPath: path) else {
            // Exists, and could not be read: permissions, an unreadable volume, or a
            // rewrite in flight. Names the fault, never the path's contents.
            return .unreadable("the file exists but its contents could not be read")
        }
        return .contents(data)
    }

    func fileContents(atPath path: String) -> Data? {
        // Size is checked BEFORE reading, not after: reading then rejecting would have
        // already done the damage the cap exists to prevent.
        if let size = (try? fileManager.attributesOfItem(atPath: path)[.size]) as? NSNumber,
           size.intValue > SystemProfileFileSystem.maximumIdentityFileBytes {
            NSLog("%@", "🔎 Skipping oversized profile config (\(size.intValue) bytes): \(path)")
            return nil
        }
        return fileManager.contents(atPath: path)
    }
}
