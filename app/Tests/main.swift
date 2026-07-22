import Foundation

// Tasks 4-8 add the remaining cases from §10 of the design.
TestHarness.check(
    "fixtures directory is present",
    FileManager.default.fileExists(atPath: TestHarness.fixturesDirectory.path)
)

UsageModelTests.run()

TestHarness.finish()
