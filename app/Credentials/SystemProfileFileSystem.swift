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
