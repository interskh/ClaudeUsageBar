import Foundation

// Minimal harness for the pure-logic test target. No networking, no Keychain,
// no SwiftUI — those stay in the app target.
enum TestHarness {
    private(set) static var failures: [String] = []
    private(set) static var passed: Int = 0

    // Recorded fixtures live next to this file. build.sh compiles the test target
    // from absolute paths, so #filePath is absolute and a test can load a payload
    // without depending on the working directory the runner was invoked from.
    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passed += 1
        } else {
            failures.append(name)
        }
    }

    static func expect<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("\(name): expected \(expected), got \(actual)")
        }
    }

    static func finish() -> Never {
        // A suite that ran nothing must not report success — a green vacuous run
        // is indistinguishable from a passing one to whoever reads the exit code.
        precondition(passed + failures.count > 0, "no checks ran")
        for failure in failures {
            FileHandle.standardError.write("❌ \(failure)\n".data(using: .utf8)!)
        }
        if failures.isEmpty {
            print("✅ \(passed) checks passed")
            exit(0)
        }
        print("❌ \(failures.count) failed, \(passed) passed")
        exit(1)
    }
}
