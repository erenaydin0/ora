import Foundation
import Testing
@testable import ora

/// Kanal başına dil (COMPETITION.md §4.8): mikrofon ve sistem sesi ayrı
/// dillerde çözülebilir.
@Suite("Kanal başına dil", .serialized)
struct ChannelLanguageTests {

    private let tr = Locale(identifier: "tr-TR")
    private let en = Locale(identifier: "en-US")

    /// Tespit çağrılarını sayan sahte.
    private final class Detector: @unchecked Sendable {
        var calls: [Channel] = []
        let answers: [Channel: Locale]
        init(_ answers: [Channel: Locale]) { self.answers = answers }
        func detect(_ channel: Channel) -> Locale {
            calls.append(channel)
            return answers[channel] ?? Locale(identifier: "tr-TR")
        }
    }

    @Test
    func karsiTarafAyniysaTekDil() async {
        let detector = Detector([:])
        let locales = await MeetingPipeline.channelLocales(
            meeting: .turkish, remote: nil, lanes: 2) { detector.detect($0) }
        #expect(locales == ChannelLocales(tr))
        #expect(!locales.isMixed)
        #expect(detector.calls.isEmpty, "dil seçiliyken tespit yapılmaz")
    }

    @Test
    func karsiTarafinDiliAyricaSecilir() async {
        let locales = await MeetingPipeline.channelLocales(
            meeting: .turkish, remote: .english, lanes: 2) { _ in Locale(identifier: "xx") }
        #expect(locales.mic == tr)
        #expect(locales.system == en)
        #expect(locales.locale(for: .system) == en)
        #expect(locales.distinct == [tr, en])
    }

    /// İçe aktarılan tek şeritli seste kanal ayrımı yok: tek dil.
    @Test
    func tekSeritliSesTekDildir() async {
        let locales = await MeetingPipeline.channelLocales(
            meeting: .turkish, remote: .english, lanes: 1) { _ in Locale(identifier: "xx") }
        #expect(locales == ChannelLocales(tr))
    }

    /// "Otomatik" her kanal için o kanalın sesine bakar.
    @Test
    func otomatikHerKanaliKendiSesindenSecer() async {
        let detector = Detector([.mic: tr, .system: en])
        let locales = await MeetingPipeline.channelLocales(
            meeting: .automatic, remote: .automatic, lanes: 2) { detector.detect($0) }
        #expect(locales == ChannelLocales(mic: tr, system: en))
        #expect(detector.calls == [.mic, .system])
    }

    @Test
    func otomatikToplantiDiliKarsiTarafaDaGecer() async {
        let detector = Detector([.mic: en])
        let locales = await MeetingPipeline.channelLocales(
            meeting: .automatic, remote: nil, lanes: 2) { detector.detect($0) }
        #expect(locales == ChannelLocales(en))
        #expect(detector.calls == [.mic], "tek tespit")
    }

    @Test
    func ayarKaliciVeVarsayilaniAynidir() {
        let suite = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = OraSettings(defaults: defaults)
        #expect(settings.remoteLanguage == nil)
        #expect(settings.liveLocales == ChannelLocales(tr))

        settings.remoteLanguage = .english
        #expect(OraSettings(defaults: defaults).remoteLanguage == .english)
        #expect(settings.liveLocales == ChannelLocales(mic: tr, system: en))

        // Canlı akışta dil tanıma yok: "Otomatik" toplantı diliyle başlar.
        settings.remoteLanguage = .automatic
        #expect(settings.liveLocales == ChannelLocales(tr))

        settings.remoteLanguage = nil
        #expect(OraSettings(defaults: defaults).remoteLanguage == nil)
    }

    /// Hat kararı tam geçişe iletir. Okunamayan dosya tek şeritli sayılır.
    @Test
    func tamGecisKanalDilleriniAlir() async throws {
        let audio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ora-test-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: audio) }

        let transcription = FakeTranscription(segments: [
            Segment(channel: .system, speaker: "Katılımcı", text: "hello",
                    start: 0, end: 2, confidence: 0.9, words: [])])
        let h = try Harness(intelligence: SlowIntelligence(tag: "A", step: .milliseconds(5)),
                            transcription: transcription)
        h.settings.remoteLanguage = .english
        let id = try await h.store.createMeeting()
        try await h.store.markProcessing(id, audioPath: audio, duration: 2)
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("yeniden deneme mümkün") { h.controller.canRetry }

        await h.controller.retryProcessing()

        #expect(transcription.seen.last == ChannelLocales(tr),
                "tek şeritli (okunamayan) dosyada karşı tarafın dili uygulanmaz")
    }
}
