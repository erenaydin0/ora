import Foundation

/// Kullanıcının bağlayabileceği dış hizmetler (Bağlantı Kuralları, CLAUDE.md).
/// Hiçbiri kurulu gelmez; bağlanmamış bir hizmete istek atılmaz.
nonisolated enum ConnectionKind: String, CaseIterable, Sendable, Identifiable, Codable {
    case anthropic
    /// ChatGPT aboneliğiyle giriş (Codex'in "Sign in with ChatGPT" akışı).
    /// OpenAI aboneliğin üçüncü taraf araçlarda kullanılmasını destekliyor.
    case chatGPT
    case openAI
    case openRouter
    /// Ollama, LM Studio gibi OpenAI uyumlu bir sunucu. Varsayılan adres bu
    /// Mac'tir; o durumda veri cihazdan çıkmaz.
    case localServer
    case slack
    case notion

    var id: String { rawValue }

    static let aiProviders: [ConnectionKind] = [.chatGPT, .anthropic, .openAI, .openRouter,
                                                 .localServer]

    var isAIProvider: Bool { Self.aiProviders.contains(self) }

    /// Sağlayıcı adları özel isimdir, çevrilmez (kural 10).
    var displayName: String {
        switch self {
        case .anthropic:   "Anthropic (Claude)"
        case .chatGPT:     "ChatGPT (abonelik)"
        case .openAI:      "OpenAI"
        case .openRouter:  "OpenRouter"
        case .localServer: "Yerel sunucu (Ollama · LM Studio)"
        case .slack:       "Slack"
        case .notion:      "Notion"
        }
    }

    /// "Slack'e gönder…" — Türkçe yönelme eki okunuşa uyar, yazılışa değil.
    var sendLabel: String {
        switch self {
        case .slack:  "Slack'e gönder…"
        case .notion: "Notion'a gönder…"
        default:      "\(displayName) hizmetine gönder…"
        }
    }

    /// Elle girilen bir anahtar mı? Yerel sunucu çoğu zaman istemez;
    /// ChatGPT'de anahtar yerine tarayıcıdan giriş yapılır.
    var needsSecret: Bool { self != .localServer && self != .chatGPT }

    var secretLabel: String {
        switch self {
        case .slack:  "Gelen webhook adresi"
        case .notion: "Entegrasyon anahtarı"
        default:      "API anahtarı"
        }
    }

    /// Model adı boş bırakılırsa kullanılan. Yalnızca Anthropic için bir
    /// varsayılan veriliyor; diğer sağlayıcılarda model kataloğu değiştiği için
    /// kullanıcı panelindeki adı yazar.
    var defaultModel: String {
        self == .anthropic ? "claude-opus-5" : ""
    }

    /// OpenAI uyumlu uç noktanın kökü.
    var defaultBaseURL: String? {
        switch self {
        case .chatGPT:     "https://chatgpt.com/backend-api/codex"
        case .openAI:      "https://api.openai.com/v1"
        case .openRouter:  "https://openrouter.ai/api/v1"
        case .localServer: "http://localhost:11434/v1"
        default:           nil
        }
    }
}

/// Giden isteğin amacı — günlükte ve izin kapısında kullanılır.
nonisolated enum OutboundPurpose: String, Sendable, Codable {
    case summary = "özet"
    case chat = "sohbet"
    case share = "paylaşım"
    /// Abonelik girişi, token yenileme ve model listesi. Toplantı verisi
    /// taşımaz; kullanıcının başlattığı girişin parçasıdır.
    case signIn = "oturum"
    /// Kullanıcının "Bağlantıyı dene" düğmesi. Toplantı verisi taşımaz, bu
    /// yüzden onay istemez.
    case test = "bağlantı denemesi"
}
