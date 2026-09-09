import Foundation
import Testing
@testable import ora

/// Kayıt oturumu (REFACTOR.md Adım 3). Ayrılmasının ölçülebilir kazancı bu
/// takım: kayıt sürerkenin davranışı artık gerçek ses donanımı ve gerçek
/// Speech olmadan denetlenebiliyor.
@Suite("Kayıt oturumu", .serialized)
struct RecordingSessionTests {

    @Test @MainActor
    func basariliBaslangicVeDurdurma() async throws {
        let url = URL(fileURLWithPath: "/tmp/ora-test.wav")
        let capture = FakeCapture(stopURL: url)
        let live = FakeLiveTranscription()
        let session = RecordingSession(capture: capture, makeLive: { live })

        #expect(!session.isRecording)
        #expect(session.meetingID == nil)

        try await session.start(meetingID: 42, preferredApp: nil)
        await waitUntil("kayıt sürüyor") { session.isRecording }
        #expect(session.meetingID == 42)
        #expect(capture.startCount == 1)

        await session.startLive(locale: Locale(identifier: "tr-TR"), vocabulary: [])
        #expect(await live.startCount == 1)
        #expect(session.liveNotice == nil, "duraklama yok, not da yok")

        let stopped = try await session.stop()
        #expect(stopped == url)
        #expect(session.meetingID == nil, "oturum kapandı")
        #expect(await live.didFinish, "canlı transkripsiyon kapatıldı")
    }

    /// Ses yazımı başlamazsa oturum **açılmaz**: `meetingID` boş kalır, yoksa
    /// `stop()` var olmayan bir kaydı kapatmaya çalışır.
    @Test @MainActor
    func basarisizBaslangicOturumAcmaz() async throws {
        let capture = FakeCapture()
        capture.startError = .permissionDenied(.microphone)
        let session = RecordingSession(capture: capture, makeLive: { FakeLiveTranscription() })

        await #expect(throws: OraError.self) {
            try await session.start(meetingID: 7, preferredApp: nil)
        }
        #expect(session.meetingID == nil)
        #expect(!session.isRecording)
    }

    /// **CLAUDE.md kural #2:** canlı transkripsiyon asla kaydın önüne geçmez.
    /// Duraklarsa kullanıcıya Türkçe not düşer ve kayıt kesintisiz sürer.
    @Test @MainActor
    func canliTranskripsiyonDuraklarsaKayitSurer() async throws {
        let capture = FakeCapture()
        let live = FakeLiveTranscription(pausesOnStart: "Canlı transkript başlatılamadı")
        let session = RecordingSession(capture: capture, makeLive: { live })

        try await session.start(meetingID: 1, preferredApp: nil)
        await waitUntil("kayıt sürüyor") { session.isRecording }
        await session.startLive(locale: Locale(identifier: "tr-TR"), vocabulary: [])

        #expect(session.liveNotice == "Canlı transkript başlatılamadı",
                "kullanıcıya Türkçe not düştü")
        #expect(session.isRecording, "KAYIT SÜRÜYOR — kural #2")
        #expect(session.meetingID == 1)

        let url = try await session.stop()
        #expect(url == capture.stopURL, "ses dosyası yine de üretildi")
    }

    /// Kesinleşen satır listeye girer ve sıralanır; kesinleşmeyen metin
    /// kanal başına ayrı tutulur.
    @Test @MainActor
    func canliGuncellemelerEkranaYazilir() async throws {
        let capture = FakeCapture()
        let live = FakeLiveTranscription()
        let session = RecordingSession(capture: capture, makeLive: { live })
        try await session.start(meetingID: 1, preferredApp: nil)
        await session.startLive(locale: Locale(identifier: "tr-TR"), vocabulary: [])

        await live.emit(LiveUpdate(channel: .system, text: "sonra gelen",
                                   isFinal: true, start: 10, end: 12))
        await live.emit(LiveUpdate(channel: .mic, text: "önce gelen",
                                   isFinal: true, start: 0, end: 2))
        await live.emit(LiveUpdate(channel: .mic, text: "akan metin",
                                   isFinal: false, start: 3, end: 4))

        await waitUntil("iki kesin satır geldi") { session.liveSegments.count == 2 }
        #expect(session.liveSegments.map(\.text) == ["önce gelen", "sonra gelen"],
                "zamana göre sıralı")
        await waitUntil("akan metin geldi") {
            session.volatileText[Channel.mic.rawValue] == "akan metin"
        }

        session.clearLive()
        #expect(session.liveSegments.isEmpty)
        #expect(session.volatileText.isEmpty)
    }

    /// Yakalama akışı hata bildirirse hata dışarı verilir — sessiz çökme yasak.
    @Test @MainActor
    func yakalamaHatasiDisariVerilir() async throws {
        let capture = FakeCapture()
        capture.startError = .permissionDenied(.systemAudio)
        let session = RecordingSession(capture: capture, makeLive: { FakeLiveTranscription() })
        var received: OraError?
        session.onError = { received = $0 }

        try? await session.start(meetingID: 1, preferredApp: nil)
        await waitUntil("hata dışarı verildi") { received != nil }
    }
}
