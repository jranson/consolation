import Foundation
import Testing
@testable import Consolation

@MainActor
struct AppModelTests {
    private func defaults() -> UserDefaults {
        let name = "ConsolationTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        store.removePersistentDomain(forName: name)
        return store
    }

    private func documents() -> any DocumentStore {
        DefaultsDocumentStore(defaults: defaults())
    }

    @Test func noSourceMeansNoNetwork() {
        let sources = SourceStore(documents: documents(), defaults: defaults())
        let model = LiveTVModel(sources: sources, favorites: AppFavorites(documents: documents(), defaults: defaults()))
        model.refresh(force: true)
        model.startTunerStatus()
        #expect(model.status == .notConfigured)
        #expect(model.channels.isEmpty)
        #expect(model.tuners.isEmpty)
    }

    @Test func deviceFavoritesWinOverAppFavorites() {
        let favorites = AppFavorites(documents: documents(), defaults: defaults())
        favorites.toggle("tvch:Antenna:9.1")
        favorites.toggle("tvch:Antenna:20.4")
        let dropped = favorites.reconcile(deviceFavorites: ["tvch:Antenna:9.1", "tvch:Antenna:2.1"])
        #expect(dropped == ["tvch:Antenna:9.1"])
        #expect(favorites.keys == ["tvch:Antenna:20.4"])
        #expect(favorites.mark(for: "tvch:Antenna:9.1", isDeviceFavorite: true) == .device)
        #expect(favorites.mark(for: "tvch:Antenna:20.4", isDeviceFavorite: false) == .app)
        #expect(favorites.mark(for: "tvch:Antenna:7.1", isDeviceFavorite: false) == FavoriteMark.none)
    }

    @Test func viewModesFilterAndOrder() {
        let url = URL(string: "http://192.0.2.10:5004/auto/v1.1")!
        func channel(_ number: String, _ mark: FavoriteMark) -> LiveChannel {
            LiveChannel(key: number, guideNumber: number, name: number, streamURL: url, isHD: true, favorite: mark)
        }
        let all = [channel("2.1", .none), channel("4.1", .device), channel("7.1", .app), channel("9.1", .none)]
        #expect(LiveTVViewMode.favoritesOnly.apply(to: all).map(\.guideNumber) == ["4.1", "7.1"])
        #expect(LiveTVViewMode.favoritesFirst.apply(to: all).map(\.guideNumber) == ["4.1", "7.1", "2.1", "9.1"])
        #expect(LiveTVViewMode.byChannel.apply(to: all).map(\.guideNumber) == ["2.1", "4.1", "7.1", "9.1"])
        #expect(LiveTVViewMode.defaultMode == .favoritesOnly)
    }

    @Test func nowPlayingAndHiddenPanesAreNeverRestored() {
        #expect(ShellModel.restorable(.nowPlaying, hidden: []) == .home)
        #expect(ShellModel.restorable(.liveTV, hidden: [.liveTV]) == .home)
        #expect(ShellModel.restorable(.quickPlay, hidden: []) == .quickPlay)
    }

    @Test func tunerReleaseIsClampedToOneToSixtyMinutes() {
        #expect(PlaybackPreferences.clampedRelease(0) == 1)
        #expect(PlaybackPreferences.clampedRelease(90) == 60)
        #expect(PlaybackPreferences(defaults: defaults()).tunerReleaseMinutes == 10)
    }

    @Test func quickPlayHistoryDedupesCapsAndHidesQueries() {
        let history = QuickPlayHistory(documents: documents(), defaults: defaults())
        for index in 0..<(QuickPlayHistory.maxEntries + 5) {
            history.record(URL(string: "https://example.com/\(index).m3u8")!)
        }
        history.record(URL(string: "https://example.com/3.m3u8")!)
        #expect(history.entries.count == QuickPlayHistory.maxEntries)
        #expect(history.entries.first?.url.absoluteString == "https://example.com/3.m3u8")
        let entry = QuickPlayEntry(url: URL(string: "https://example.com/a.m3u8?token=secret")!, lastPlayed: .now)
        #expect(entry.displayString == "https://example.com/a.m3u8?…")
        history.isEnabled = false
        #expect(history.entries.isEmpty)
    }

    @Test func documentsRoundTripAndMigrateFromDefaults() {
        let directory = URL.temporaryDirectory.appending(path: "ConsolationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FileDocumentStore(directory: directory)
        files.save(["tvch:Antenna:9.1"], named: "favorites")
        #expect(files.load([String].self, named: "favorites") == ["tvch:Antenna:9.1"])
        files.save(nil as [String]?, named: "favorites")
        #expect(files.data(named: "favorites") == nil)

        let legacy = defaults()
        legacy.set(["tvch:Antenna:7.1"], forKey: AppIdentifier.scoped("liveTV.appFavorites"))
        let favorites = AppFavorites(documents: files, defaults: legacy)
        #expect(favorites.keys == ["tvch:Antenna:7.1"])
        #expect(legacy.object(forKey: AppIdentifier.scoped("liveTV.appFavorites")) == nil)
        #expect(AppFavorites(documents: files, defaults: legacy).keys == ["tvch:Antenna:7.1"])
    }
}

@MainActor
struct GuideTimeSlotTests {
    @Test func slotsStartOnTheHalfHourContainingNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Denver"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 14,
                                                                  minute: 47, second: 12)))
        let slots = GuideTimeSlots.slots(containing: now, count: 3, calendar: calendar)
        #expect(slots.map { calendar.component(.minute, from: $0) } == [30, 0, 30])
        #expect(calendar.component(.hour, from: slots[0]) == 14)
        #expect(abs(GuideTimeSlots.progress(of: now, in: slots[0]) - 1_032.0 / 1_800) < 0.001)
    }
}
