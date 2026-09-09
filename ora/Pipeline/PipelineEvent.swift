import Foundation

/// İşlem hattının aşaması. Toplantı **başına** tutulur (`stages`); uygulama
/// genelinde tek bir aşama, kullanıcı işlem sürerken başka bir toplantıya
/// geçtiğinde animasyonu o toplantının ekranına taşıyordu (RESEARCH.md §27).
nonisolated enum PipelineStage: Equatable, Sendable {
    case idle
    /// İçe aktarılan ses hattın biçimine çevriliyor. Hat henüz başlamadı;
    /// aşamayı bu adım için `MeetingImporter` bildirir — ekranda bekleyen
    /// kullanıcı "hiçbir şey olmuyor" görmesin.
    case importing(Double)
    case preparingLanguage
    case downloadingLanguage(Double)
    case transcribing(Double)
    case punctuating(Double)
    case summarizing(Double)
    case done

    /// Hat koşuyor mu. `.idle` ve `.done` ikisi de "koşmuyor" demektir;
    /// arayüz bu ikisini ayırt etmez.
    var isActive: Bool {
        switch self {
        case .idle, .done: false
        default: true
        }
    }
}

/// Hattın ürettiği her şey bu olayla dışarı çıkar ve **hangi toplantıya ait
/// olduğunu taşır.**
///
/// Neden olay: hat, ürettiği içeriği doğrudan yayınlanan duruma yazdığı sürece
/// her yazımın önünde elle konmuş bir "kullanıcı hâlâ bu toplantıya mı bakıyor"
/// kapısı gerekiyordu — 15 tane olmuştu ve unutulan her biri sessiz bir
/// toplantılar-arası sızıntıydı (REFACTOR.md §2). Olay `meetingID` taşıdığı
/// için süzme **tek yerde**, `RecordingController.apply(_:)` içinde yapılır.
nonisolated struct PipelineEvent: Sendable {

    let meetingID: Int64
    let kind: Kind

    enum Kind: Sendable {
        // MARK: Seçimden bağımsız — hangi toplantı ekranda olursa olsun işlenir

        /// Aşama ilerledi. Yetki kapıları (`isTranscribing`) buna bakar.
        case stage(PipelineStage)
        /// Hat hata verdi; kullanıcıya Türkçe ulaşır.
        case failed(OraError)
        /// Veritabanı değişti — liste ve aksiyon panosu tazelenmeli.
        case storeChanged
        /// Hat bitti; bildirim gönderilebilir.
        case finished(title: String)

        // MARK: Yalnızca o toplantı ekrandayken arayüze yazılır

        case transcript([Segment])
        case summary(Ozet?, [TopicSegment])
        case actions([MeetingAction])
        /// Ses dosyası hazır ya da yeri değişti (sıkıştırma).
        case audio(URL)
        /// Kullanıcıya düşülecek Türkçe not (özet eksik, model kapalı, …).
        case notice(String)
        /// Güç/termal nedeniyle özetleme ertelendi.
        case deferred(PowerState.DeferReason)
        /// Erteleme kalktı.
        case deferCleared
        /// İşlem başarısız; ham ses diskte, "Yeniden dene" bu dosyayı işler.
        case retryable(URL)
    }
}
