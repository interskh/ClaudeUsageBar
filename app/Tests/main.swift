import Foundation

// Task 8 adds the remaining cases from §10 of the design.
TestHarness.check(
    "fixtures directory is present",
    FileManager.default.fileExists(atPath: TestHarness.fixturesDirectory.path)
)

UsageModelTests.run()
ClaudeProfileDiscoveryTests.run()
AnthropicProviderTests.run()
CodexProviderTests.run()
// `UsageEngine` is @MainActor — that is how §6's single-writer rule is checked
// rather than asserted. Top-level code is not actor-isolated in Swift 5 mode but does
// run on the main thread, which is what the isolation actually requires.
MainActor.assumeIsolated { UsageEngineTests.run() }

TestHarness.finish()
