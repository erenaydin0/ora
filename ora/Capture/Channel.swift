import Foundation

/// Stereo kaydın kanalları. Kanallar asla tek kanala karıştırılmaz (CLAUDE.md kural #11).
enum Channel: Int, CaseIterable, Sendable {
    /// WAV kanal 0 — mikrofon, yani kullanıcının kendisi.
    case mic = 0
    /// WAV kanal 1 — sistem sesi, yani toplantıdaki diğer katılımcılar.
    case system = 1

    /// Faz 3'te transkript segmentlerine yazılacak konuşmacı adı.
    var speaker: String {
        switch self {
        case .mic:    "Ben"
        case .system: "Katılımcı"
        }
    }

    /// `transcripts.channel` sütununun değeri.
    var databaseValue: String {
        switch self {
        case .mic:    "mic"
        case .system: "system"
        }
    }
}
