import Foundation
import Testing
@testable import WandelBar

@Test func menuBarSetupReminderPersistsAcrossLaunches() throws {
    let suite = "WandelBar.SetupTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstLaunch = MenuBarSetupNoticeState(defaults: defaults)
    #expect(!firstLaunch.shouldPresent(macOSMajorVersion: 14))
    #expect(!firstLaunch.shouldPresent(macOSMajorVersion: 15))
    #expect(firstLaunch.shouldPresent(macOSMajorVersion: 26))
    firstLaunch.acknowledge()
    let nextLaunch = MenuBarSetupNoticeState(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(!nextLaunch.shouldPresent(macOSMajorVersion: 26))
    #expect(!nextLaunch.shouldPresent(macOSMajorVersion: 27))
}
