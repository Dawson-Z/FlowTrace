//
//  SettingsStoreTests.swift
//  FlowTraceTests
//
//  I 组：SettingsStore 单测（5 项）
//  默认值、重命名迁移、键写入往返、NSApp.appearance 映射、$prop.dropFirst 不触发写。
//

import XCTest
import AppKit
@testable import FlowTrace

final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FlowTraceTests.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // I1: 默认值（与 ARCHITECTURE §6 一致）
    func testDefaults() {
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.defaultSortModeRaw, "download")
        XCTAssertEqual(s.appearanceRaw, "system")
        XCTAssertTrue(s.showDownloadInStatusBar)
        XCTAssertTrue(s.showUploadInStatusBar)
        XCTAssertEqual(s.historyRetentionDays, 30)
        XCTAssertEqual(s.cleanupModeRaw, "manualNotification")
        XCTAssertEqual(s.retentionTimeOfDay, 12 * 3600)
        XCTAssertNil(s.languageOverride)
        XCTAssertFalse(s.quotaEnabled)
        XCTAssertEqual(s.quotaPeriod, "month")
        XCTAssertEqual(s.quotaLimitGB, 100)
        XCTAssertEqual(s.quotaCustomPercent, 0)
        XCTAssertFalse(s.showTodayInMenuBar)
        XCTAssertFalse(s.showPeriodInMenuBar)
        XCTAssertFalse(s.showLogoInMenuBar)
        XCTAssertTrue(s.showProcessListInPopover)
        XCTAssertTrue(s.showInterfacesInPopover)
        XCTAssertTrue(s.showSparklineInPopover)
        XCTAssertTrue(s.showTodayPeakInPopover)
        XCTAssertTrue(s.showTodayTotalInPopover)
        XCTAssertTrue(s.showHistoryEntryInPopover)
        XCTAssertFalse(s.uploadAlertEnabled)
        XCTAssertEqual(s.alertDownloadMultiplier, 10)
        XCTAssertEqual(s.alertUploadMultiplier, 10)
        XCTAssertEqual(s.alertMinDownloadMB, 500)
        XCTAssertEqual(s.alertMinUploadMB, 500)
        XCTAssertEqual(s.refreshInterval, 1)
    }

    // I2: showMonthInMenuBar → showPeriodInMenuBar 重命名迁移
    func testMigrationRenamesShowMonthInMenuBar() {
        defaults.set(true, forKey: "showMonthInMenuBar")
        let s = SettingsStore(defaults: defaults)
        XCTAssertTrue(s.showPeriodInMenuBar, "old showMonthInMenuBar=true should migrate to showPeriodInMenuBar")
        XCTAssertNil(defaults.object(forKey: "showMonthInMenuBar"), "old key should be removed")
    }

    // I4: 修改属性会落 UserDefaults（sink 路径）
    func testSettingAPersists() {
        let s = SettingsStore(defaults: defaults)
        s.quotaLimitGB = 50
        // 等 sink 触发
        XCTAssertEqual(defaults.integer(forKey: "quotaLimitGB"), 50)
    }

    // I3: applyAppearance 映射到 NSApp.appearance
    func testApplyAppearance() {
        let s = SettingsStore(defaults: defaults)
        s.appearanceRaw = "light"
        // 等 sink + DispatchQueue.main.async
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(NSApp.appearance?.name, .aqua)

        s.appearanceRaw = "dark"
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)

        s.appearanceRaw = "system"
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(NSApp.appearance)
    }

    // I6: quotaLimitGB 钳制（在 QuotaMonitor.config() 中）
    func testQuotaLimitClamping() {
        let s = SettingsStore(defaults: defaults)
        let agg = UsageAggregator()
        let monitor = QuotaMonitor(settings: s, aggregator: agg, defaults: defaults)
        s.quotaLimitGB = 0
        XCTAssertGreaterThanOrEqual(monitor.config().limitBytes, 1024 * 1024 * 1024,
                                    "quotaLimitGB=0 must clamp to at least 1GB")
    }

    // I6b: 历史保留天数默认 30
    func testHistoryRetentionDaysDefault() {
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.historyRetentionDays, 30)
        s.historyRetentionDays = 7
        XCTAssertEqual(s.historyRetentionDays, 7)
    }

    // L2-23: 26 个持久化 key 全量往返（launchAtLogin 除外——它以系统登录项为权威，
    // 不经 UserDefaults，见 ARCHITECTURE §6 的「不由 SettingsStore 拥有的 key」）
    func testAllPersistedKeysRoundTrip() {
        let writer = SettingsStore(defaults: defaults)

        writer.defaultSortModeRaw      = "cumulativeTotal"
        writer.appearanceRaw           = "dark"
        writer.showDownloadInStatusBar = false
        writer.showUploadInStatusBar   = false
        writer.historyRetentionDays    = 14
        writer.cleanupModeRaw          = "automatic"
        writer.retentionTimeOfDay      = 3 * 3600
        writer.languageOverride        = "fr"
        writer.quotaEnabled            = true
        writer.quotaPeriod             = "week"
        writer.quotaLimitGB            = 42
        writer.quotaCustomPercent      = 85
        writer.showTodayInMenuBar      = true
        writer.showPeriodInMenuBar     = true
        writer.showLogoInMenuBar       = true
        writer.showProcessListInPopover  = false
        writer.showInterfacesInPopover   = false
        writer.showSparklineInPopover    = false
        writer.showTodayPeakInPopover    = false
        writer.showTodayTotalInPopover   = false
        writer.showHistoryEntryInPopover = false
        writer.uploadAlertEnabled      = true
        writer.alertDownloadMultiplier = 7
        writer.alertUploadMultiplier   = 8
        writer.alertMinDownloadMB      = 123
        writer.alertMinUploadMB        = 456

        // 新实例必须读到同样的值（证明每个 key 都真的落到了 defaults）
        let reader = SettingsStore(defaults: defaults)
        XCTAssertEqual(reader.defaultSortModeRaw, "cumulativeTotal")
        XCTAssertEqual(reader.appearanceRaw, "dark")
        XCTAssertFalse(reader.showDownloadInStatusBar)
        XCTAssertFalse(reader.showUploadInStatusBar)
        XCTAssertEqual(reader.historyRetentionDays, 14)
        XCTAssertEqual(reader.cleanupModeRaw, "automatic")
        XCTAssertEqual(reader.retentionTimeOfDay, 3 * 3600)
        XCTAssertEqual(reader.languageOverride, "fr")
        XCTAssertTrue(reader.quotaEnabled)
        XCTAssertEqual(reader.quotaPeriod, "week")
        XCTAssertEqual(reader.quotaLimitGB, 42)
        XCTAssertEqual(reader.quotaCustomPercent, 85)
        XCTAssertTrue(reader.showTodayInMenuBar)
        XCTAssertTrue(reader.showPeriodInMenuBar)
        XCTAssertTrue(reader.showLogoInMenuBar)
        XCTAssertFalse(reader.showProcessListInPopover)
        XCTAssertFalse(reader.showInterfacesInPopover)
        XCTAssertFalse(reader.showSparklineInPopover)
        XCTAssertFalse(reader.showTodayPeakInPopover)
        XCTAssertFalse(reader.showTodayTotalInPopover)
        XCTAssertFalse(reader.showHistoryEntryInPopover)
        XCTAssertTrue(reader.uploadAlertEnabled)
        XCTAssertEqual(reader.alertDownloadMultiplier, 7)
        XCTAssertEqual(reader.alertUploadMultiplier, 8)
        XCTAssertEqual(reader.alertMinDownloadMB, 123)
        XCTAssertEqual(reader.alertMinUploadMB, 456)
    }
}