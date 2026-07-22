import Foundation

// Tasks 6-8 add the remaining cases from §10 of the design.
TestHarness.check(
    "fixtures directory is present",
    FileManager.default.fileExists(atPath: TestHarness.fixturesDirectory.path)
)

UsageModelTests.run()
ClaudeProfileDiscoveryTests.run()
AnthropicProviderTests.run()

TestHarness.finish()
