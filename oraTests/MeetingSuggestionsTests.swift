import Foundation
import Testing
@testable import ora

/// Algılama → öneri → karar zinciri (REFACTOR.md Adım 4).
///
/// En önemli testi ilki: öneri teslimi bir saniyelik `while` döngüsünden
/// `withObservationTracking`'e taşındı. Gözlemleme sessizce tetiklenmezse
/// öneriler hiç görünmez ve bunu yakalayacak başka bir şey yok.
@Suite("Toplantı önerileri", .serialized)
struct MeetingSuggestionsTests {

    private func make(settings: OraSettings? = nil,
                      event: MeetingEvent? = nil)
    -> (FakeDetector, FakeSuggestionNotifier, OraSettings, MeetingSuggestions) {
        let suite = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let resolved = settings ?? OraSettings(defaults: defaults)
        let detector = FakeDetector()
        let notifier = FakeSuggestionNotifier()
        let suggestions = MeetingSuggestions(detector: detector, notifications: notifier,
                                             settings: resolved,
                                             matchingEvent: { _ in event })
        return (detector, notifier, resolved, suggestions)
    }

    /// **Polling → gözlemleme.** Sinyal düştüğü anda bildirim gidiyor mu?
    @Test
    func sinyalGelinceBildirimGonderilir() async {
        let (detector, notifier, _, suggestions) = make()
        suggestions.start()
        #expect(detector.startCount == 1, "algılama açıldı")
        #expect(notifier.suggested.isEmpty, "sinyal yokken bildirim yok")

        detector.emit(testSignal())

        await waitUntil("bildirim gönderildi") { notifier.suggested.count == 1 }
        #expect(notifier.suggested.first?.signal.bundleID == "com.microsoft.teams2")
        #expect(suggestions.pendingSignal != nil, "öneri arayüzde de duruyor")
    }

    /// Aynı öneri için ikinci bildirim gönderilmez; sinyal düşüp yeniden
    /// gelirse gönderilir.
    @Test
    func ayniOneriIcinIkinciBildirimYok() async {
        let (detector, notifier, _, suggestions) = make()
        suggestions.start()

        detector.emit(testSignal())
        await waitUntil("ilk bildirim") { notifier.suggested.count == 1 }
        detector.emit(testSignal())
        await settle(.milliseconds(150))
        #expect(notifier.suggested.count == 1, "aynı uygulama için tek bildirim")

        detector.emit(nil)
        await settle(.milliseconds(150))
        detector.emit(testSignal())
        await waitUntil("sinyal düşüp döndü, yeniden bildirildi") {
            notifier.suggested.count == 2
        }
    }

    /// Öneri kabul edilince kaydı **çağıran** başlatır ve öneri düşer.
    @Test
    func kabulKaydiBaslatir() async {
        let (detector, _, _, suggestions) = make()
        var started: [String] = []
        suggestions.onRecord = { started.append($0.bundleID) }
        suggestions.start()
        detector.emit(testSignal())

        suggestions.accept()

        #expect(started == ["com.microsoft.teams2"])
        #expect(detector.dismissCount == 1, "öneri düşürüldü — soğuma başlar")
        #expect(suggestions.pendingSignal == nil)
    }

    /// Ret kayıt başlatmaz.
    @Test
    func redKayitBaslatmaz() async {
        let (detector, _, _, suggestions) = make()
        var started = 0
        suggestions.onRecord = { _ in started += 1 }
        suggestions.start()
        detector.emit(testSignal())

        suggestions.dismiss()

        #expect(started == 0, "İZİNSİZ OTOMATİK KAYIT YOK")
        #expect(detector.dismissCount == 1)
    }

    /// "Her zaman kaydet" seçili uygulamada algılayıcı kendisi başlatır.
    @Test
    func otomatikBaslatmaOnRecordTetikler() async {
        let (detector, _, _, suggestions) = make()
        var started: [String] = []
        suggestions.onRecord = { started.append($0.bundleID) }
        suggestions.start()

        detector.onAutoStart?(testSignal("com.tinyspeck.slackmacgap"))

        #expect(started == ["com.tinyspeck.slackmacgap"])
    }

    /// Bildirimdeki "Bu uygulamayı hep kaydet": ayar **her hâlükârda** yazılır.
    /// Öneri duruyorsa kayıt da başlar, düşmüşse yalnızca ayar kalır.
    @Test
    func hepKaydetAyariHerHaldeYazilir() async {
        let (detector, notifier, settings, suggestions) = make()
        var started = 0
        suggestions.onRecord = { _ in started += 1 }
        suggestions.start()

        // Öneri düşmüş: ayar yazılır, kayıt başlamaz.
        notifier.onAlways?("com.tinyspeck.slackmacgap")
        #expect(settings.alwaysRecordBundleIDs.contains("com.tinyspeck.slackmacgap"))
        #expect(started == 0, "öneri yokken kayıt başlamaz")

        // Öneri duruyor: ikisi de olur.
        detector.emit(testSignal())
        notifier.onAlways?("com.microsoft.teams2")
        #expect(settings.alwaysRecordBundleIDs.contains("com.microsoft.teams2"))
        #expect(started == 1)
    }

    /// Bildirimin "Kaydet" düğmesi yalnızca **o** sinyal için çalışır: eski bir
    /// bildirime basmak yeni toplantıyı kaydetmeye başlamamalı.
    @Test
    func bildirimDugmesiYalnizcaKendiSinyaliniBaslatir() async {
        let (detector, notifier, _, suggestions) = make()
        var started: [String] = []
        suggestions.onRecord = { started.append($0.bundleID) }
        suggestions.start()
        detector.emit(testSignal("com.microsoft.teams2"))

        notifier.onRecord?("com.zoom.xos")     // eski, artık geçerli olmayan bildirim
        #expect(started.isEmpty, "başka sinyalin bildirimi yok sayıldı")

        notifier.onRecord?("com.microsoft.teams2")
        #expect(started == ["com.microsoft.teams2"])
    }

    /// Algılama kapatılınca dinleyici de susar — kapalıyken gelen sinyal
    /// bildirim üretmez.
    @Test
    func algilamaKapatilincaTeslimDurur() async {
        let (detector, notifier, _, suggestions) = make()
        suggestions.start()
        detector.emit(testSignal())
        await waitUntil("ilk bildirim") { notifier.suggested.count == 1 }

        suggestions.setEnabled(false)
        #expect(detector.stopCount == 1)

        detector.emit(testSignal("com.zoom.xos"))
        await settle(.milliseconds(200))
        #expect(notifier.suggested.count == 1, "kapalıyken teslim yok")
    }

    /// Takvim açıksa etkinlik bildirime geçer — bu tipin Calendar'a bağlanmadan
    /// yaptığı tek iş.
    @Test
    func takvimEtkinligiBildirimeGecer() async {
        let event = MeetingEvent(eventID: "evt-1", title: "Bordro Toplantısı",
                                 start: Date(), end: Date(), organizer: nil,
                                 attendees: ["Ayşe", "Mehmet"], meetingApp: nil,
                                 isCancelled: false, myStatus: .accepted,
                                 organizerIsMe: false)
        let (detector, notifier, _, suggestions) = make(event: event)
        suggestions.start()
        detector.emit(testSignal())

        await waitUntil("bildirim gönderildi") { notifier.suggested.count == 1 }
        #expect(notifier.suggested.first?.event?.title == "Bordro Toplantısı")
    }
}
