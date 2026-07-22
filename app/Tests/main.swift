import Foundation

// Scaffold only. Tasks 4-8 add the real cases from §10 of the design.
TestHarness.check(
    "fixtures directory is present",
    FileManager.default.fileExists(atPath: TestHarness.fixturesDirectory.path)
)

TestHarness.finish()
