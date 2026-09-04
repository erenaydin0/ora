import Foundation

/// Güç ve termal kontrol.
///
/// Ayrı bir "Low Power Mode" alt sistemi **yoktur** — eski ora'da bu özellik
/// WhisperX+LLM'in dakikalarca CPU'yu meşgul etmesi yüzünden vardı. Yeni
/// ölçümlerle gerekçesi kalmadı (RESEARCH.md §8). Yerine iki satırlık kontrol:
/// biri doğruysa kayıt sonrası özetleme otomatik başlamaz, kullanıcıya sorulur.
///
/// Şarj durumu izlenmez, `IOPSCopyPowerSourcesInfo` kullanılmaz.
enum PowerState {

    enum DeferReason: Equatable {
        case lowPowerMode
        case thermalPressure

        var turkishMessage: String {
            switch self {
            case .lowPowerMode:    "Düşük Güç Modu açık"
            case .thermalPressure: "Mac ısınmış durumda"
            }
        }

        var turkishDetail: String {
            switch self {
            case .lowPowerMode:
                "Özetleme otomatik başlatılmadı. Transkript hazır; özeti şimdi "
                + "oluşturmak isterseniz başlatabilirsiniz."
            case .thermalPressure:
                "Özetleme otomatik başlatılmadı. Transkript hazır; Mac soğuduğunda "
                + "veya şimdi elle başlatabilirsiniz."
            }
        }
    }

    /// Özetlemeyi ertelemek için bir neden var mı?
    static func deferReason() -> DeferReason? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPowerMode }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return .thermalPressure }
        return nil
    }
}
