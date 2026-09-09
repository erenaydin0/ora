import Foundation
import Observation

/// Toplantı listesi, arama, seçim ve **seçili toplantının ekrandaki içeriği.**
///
/// "Ekranda ne var" bilgisinin tek sahibi burasıdır. Bu, iki yarışın da tek
/// yerde kapanması demek:
///
/// 1. **Geç gelen yükleme.** Okuma asenkron; kullanıcı hızlı git-gel yaparsa
///    eski toplantının sonucu yeni seçimin üstüne yazılabilir. `apply(_:for:)`
///    her yazımdan önce seçimi doğrular.
/// 2. **Hattın ürettiği içerik.** `MeetingPipeline` hangi toplantının ekranda
///    olduğunu bilmez ve bilmemeli; `display(_:)` süzmeyi burada yapar
///    (REFACTOR.md §2 — eskiden 15 ayrı `onScreen` çağrısıydı).
///
/// Veritabanına yazım her hâlükârda yapılır; buradaki süzme yalnızca **ekrana**
/// yazımı kısıtlar. Kullanıcı geri döndüğünde içerik veritabanından okunur.
@MainActor
@Observable
final class MeetingLibrary {

    // MARK: - Liste ve arama

    private(set) var meetings: [MeetingListItem] = []
    /// Arama sonucunun transkriptte nerede eşleştiği — toplantı başına bir
    /// parçacık. Arama boşken boştur.
    private(set) var searchSnippets: [Int64: String] = [:]
    var searchText = "" { didSet { scheduleRefresh() } }

    /// Tüm toplantıların aksiyonları — pano bunu gösterir. Toplantı seçiminden
    /// bağımsızdır; liste her tazelemede yenilenir.
    private(set) var boardActions: [BoardAction] = []
    /// Kenar çubuğundaki sayı: açık aksiyon adedi.
    var openActionCount: Int { boardActions.count { !$0.isDone } }
    /// Aksiyon panosu açık mı — açıkken orta panel toplantı yerine panoyu gösterir.
    var showsActionBoard = false { didSet { if showsActionBoard { selection = nil } } }

    var selection: Int64? {
        didSet {
            guard selection != oldValue else { return }
            if selection != nil { showsActionBoard = false }
            loadSelected()
        }
    }

    var selectedMeeting: MeetingListItem? { meetings.first { $0.id == selection } }

    // MARK: - Seçili toplantının içeriği

    private(set) var transcript: [Segment] = []
    private(set) var summary: Ozet?
    private(set) var topics: [TopicSegment] = []
    /// Aksiyonlar özetten ayrı taşınır: onay kutusu satır kimliği ister.
    private(set) var actions: [MeetingAction] = []
    private(set) var summaryNotice: String?
    /// Güç/termal nedeniyle özetleme ertelendiyse nedeni. Seçili toplantıya
    /// aittir; taşınırsa başka bir toplantının ekranında "Şimdi özetle" belirir.
    private(set) var deferReason: PowerState.DeferReason?
    /// Seçili toplantının diskteki ses dosyası — oynatıcı bunu çalar.
    private(set) var audioURL: URL?
    /// Sesi diskte duruyor ama transkripti yok — işlem yeniden denenebilir.
    /// `audioURL`'den ayrı: ses transkript **varken de** durur.
    private(set) var retryableAudio: URL?
    /// Takvimden gelen katılımcılar (Özet'te Kişiler bölümü).
    private(set) var calendarParticipants: [String] = []
    private(set) var chatTurns: [MeetingStore.ChatTurn] = []

    // MARK: - Bağımlılıklar

    private let store: MeetingStore
    /// Kayıt sürerken seçim değişse bile yükleme yapılmaz — ekranda canlı
    /// transkript akıyor.
    private let isRecording: () -> Bool
    /// Tam geçiş sonucu geldiğinde ya da başka toplantı yüklendiğinde canlı
    /// ön izleme bırakılır. Closure: kütüphane `RecordingSession`'a bağlanmaz.
    private let clearLivePreview: () -> Void

    /// Kullanıcıya Türkçe ulaşacak hata.
    var onError: ((OraError) -> Void)?
    /// Düzeltmeden çıkan kelime çifti — sözlüğe **aday** olarak eklenir.
    /// Kütüphane sözlüğe dokunmaz.
    var onCorrection: ((_ mistake: String, _ correct: String) -> Void)?

    private var refreshTask: Task<Void, Never>?

    init(store: MeetingStore,
         isRecording: @escaping () -> Bool = { false },
         clearLivePreview: @escaping () -> Void = {}) {
        self.store = store
        self.isRecording = isRecording
        self.clearLivePreview = clearLivePreview
    }

    // MARK: - Liste

    func refresh() async {
        do {
            meetings = try await store.list(search: searchText)
        } catch {
            Log.error(.store, "Toplantı listesi okunamadı", error)
        }
        boardActions = (try? await store.allActions()) ?? boardActions
        searchSnippets = (try? await store.snippets(search: searchText)) ?? [:]
    }

    /// Arama yazarken her tuşta sorgu atılmaz.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Panodan kaynak toplantıya git.
    func openMeeting(_ meetingID: Int64) {
        showsActionBoard = false
        selection = meetingID
    }

    // MARK: - Seçili toplantıyı yükleme

    /// Bu toplantı şu an ekranda mı?
    func isOnScreen(_ meetingID: Int64) -> Bool { selection == meetingID }

    private func loadSelected() {
        guard let selection, !isRecording() else { return }
        Task { [weak self] in await self?.load(selection) }
    }

    /// Seçili toplantıyı veritabanından yeniden okur.
    func reload() async {
        guard let selection else { return }
        await load(selection)
    }

    private func load(_ meetingID: Int64) async {
        do {
            guard let loaded = try await store.load(meetingID) else { return }
            let chat = (try? await store.chatHistory(meetingID)) ?? []
            let people = (try? await store.calendarParticipants(meetingID)) ?? []
            apply(loaded, chat: chat, participants: people, for: meetingID)
        } catch {
            Log.error(.store, "Toplantı yüklenemedi: \(meetingID)", error)
            onError?(.audioWriteFailed(underlying: error))
        }
    }

    /// Okunan içeriği ekrana yazar — **yalnızca o toplantı hâlâ seçiliyken.**
    ///
    /// Okuma asenkron; bu arada kullanıcı başka bir toplantıya geçmiş olabilir.
    /// Geç gelen sonuç yeni seçimin üstüne yazılmaz — hızlı git-gel'de iki
    /// yükleme yarışıyordu. Okumadan ayrı bir metot olması ölçülebilmesi için:
    /// yarışı gerçek zamanlamayla kurmak deterministik değildi.
    func apply(_ loaded: LoadedMeeting, chat: [MeetingStore.ChatTurn],
               participants: [String], for meetingID: Int64) {
        guard isOnScreen(meetingID) else { return }

        transcript = loaded.segments
        summary = loaded.summary
        topics = loaded.topics
        actions = loaded.actions
        chatTurns = chat
        calendarParticipants = participants
        summaryNotice = nil
        deferReason = nil
        // Aşama burada **kurulmaz**: hattın kendi kaydı tek kaynaktır.
        // Eskiden veritabanının yarım hâlinden türetiliyordu ve işlenmekte
        // olan toplantıya dönüldüğünde animasyon kayboluyordu (§27).
        audioURL = MeetingPipeline.existingAudio(loaded.meeting)
        retryableAudio = loaded.segments.isEmpty ? audioURL : nil
        clearLivePreview()
    }

    /// Yeni kayıt başlarken ya da seçim boşaldığında ekran temizlenir.
    func clearDisplayed() {
        transcript = []
        summary = nil
        topics = []
        actions = []
        summaryNotice = nil
        deferReason = nil
        chatTurns = []
        calendarParticipants = []
        retryableAudio = nil
        audioURL = nil
        clearLivePreview()
    }

    // MARK: - Hattın ürettiği içerik

    /// Hattın ürettiği içeriği ekrana yazar — **yalnızca o toplantı
    /// seçiliyken.** Süzmenin tek yeri budur.
    ///
    /// Seçimden bağımsız olaylar (`.stage`, `.failed`, `.storeChanged`,
    /// `.finished`) buraya hiç gelmez; onları `RecordingController` işler.
    func display(_ event: PipelineEvent) {
        guard isOnScreen(event.meetingID) else { return }
        switch event.kind {
        case .transcript(let segments):
            // Tam geçiş nihai gerçektir; canlı ön izleme bırakılır.
            transcript = segments
            clearLivePreview()
        case .summary(let ozet, let producedTopics):
            summary = ozet
            topics = producedTopics
        case .actions(let produced):
            actions = produced
        case .audio(let url):
            audioURL = url
            // Sıkıştırma dosyanın yerini değiştirdiyse "Yeniden dene" de artık
            // yeni dosyayı işler. Boşsa dokunulmaz: hattın başında yayılan ses
            // olayı düğmeyi yoktan var etmemeli.
            if retryableAudio != nil { retryableAudio = url }
        case .notice(let text):
            summaryNotice = text
        case .deferred(let reason):
            deferReason = reason
        case .deferCleared:
            deferReason = nil
        case .retryable(let url):
            retryableAudio = url
        case .stage, .failed, .storeChanged, .finished:
            break
        }
    }

    /// İşlem elle yeniden başlatılırken düğme gizlenir; sonuç boş çıkarsa
    /// `RecordingController` geri koyar.
    func clearRetryable() { retryableAudio = nil }

    /// Yeniden denemeye rağmen transkript üretilmediyse düğme geri gelir.
    func restoreRetryable(_ url: URL, for meetingID: Int64) {
        guard isOnScreen(meetingID), transcript.isEmpty else { return }
        retryableAudio = url
    }

    /// Ertelemeyi ve notu elle özetleme öncesi temizler.
    func clearSummaryNotice() {
        summaryNotice = nil
        deferReason = nil
    }

    // MARK: - Değişiklikler

    func delete(_ meetingID: Int64) async {
        do {
            try await store.delete(meetingID)
            if isOnScreen(meetingID) {
                selection = nil
                clearDisplayed()
            }
            await refresh()
        } catch {
            Log.error(.store, "Toplantı silinemedi: \(meetingID)", error)
        }
    }

    func rename(_ meetingID: Int64, to title: String) async {
        try? await store.updateTitle(meetingID, title: title)
        await refresh()
    }

    /// Transkriptte tıklayarak düzeltme — `corrections` tablosunu besler.
    /// Sözlüğe aday ekleme `onCorrection` dinleyicisinin işi.
    func correct(_ segment: Segment, to text: String) async {
        guard let meetingID = selection else { return }
        do {
            try await store.applyCorrection(meetingID: meetingID, original: segment,
                                            corrected: text)
            onCorrection?(segment.text, text)
            await load(meetingID)
        } catch {
            Log.error(.store, "Düzeltme kaydedilemedi", error)
        }
    }

    /// Transkript satırını siler. Ham ses duruyorsa "Yeniden dene" ile
    /// transkript baştan üretilebilir; bu yüzden geri alınamaz bir kayıp değil.
    func deleteSegment(_ segment: Segment) async {
        guard let meetingID = selection else { return }
        do {
            try await store.deleteSegment(meetingID: meetingID, segment: segment)
            await load(meetingID)
        } catch {
            Log.error(.store, "Satır silinemedi", error)
        }
    }

    /// Konuşmacı etiketini değiştirir (kanal değişmez).
    func setSpeaker(_ segment: Segment, to speaker: String) async {
        guard let meetingID = selection else { return }
        do {
            try await store.setSpeaker(meetingID: meetingID, segment: segment, speaker: speaker)
            await load(meetingID)
        } catch {
            Log.error(.store, "Konuşmacı değiştirilemedi", error)
        }
    }

    /// Aksiyonu tamamlandı olarak işaretler. Ekran hemen güncellenir, yazma
    /// arkada yapılır — kutuya basınca beklemek gerekmez.
    func setActionDone(_ actionID: Int64, _ done: Bool) {
        if let index = actions.firstIndex(where: { $0.id == actionID }) {
            actions[index].isDone = done
        }
        // Pano ve toplantı görünümü aynı satırı gösterebilir; ikisi de hemen
        // güncellenir.
        if let index = boardActions.firstIndex(where: { $0.id == actionID }) {
            boardActions[index].status = (done ? MeetingStore.ActionStatus.done
                                               : .pending).rawValue
        }
        Task { [store] in
            do { try await store.setActionDone(actionID, done) }
            catch { Log.error(.store, "Aksiyon durumu yazılamadı", error) }
        }
    }

    /// Sohbet turu ekler ve geçmişi tazeler.
    func appendChat(question: String, answer: String) async {
        guard let meetingID = selection else { return }
        try? await store.appendChat(meetingID, question: question, answer: answer)
        guard isOnScreen(meetingID) else { return }
        chatTurns = (try? await store.chatHistory(meetingID)) ?? []
    }
}
