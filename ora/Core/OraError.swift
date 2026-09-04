import Foundation

enum Permission: String {
    case microphone
    case systemAudio
    case speechRecognition
    case calendar

    var turkishName: String {
        switch self {
        case .microphone:        "Mikrofon"
        case .systemAudio:       "Sistem sesi"
        case .speechRecognition: "Konuşma tanıma"
        case .calendar:          "Takvim"
        }
    }
}

/// Uygulamanın tek hata tipi. Her vakanın Türkçe kullanıcı mesajı ve mümkünse
/// bir düzeltici eylemi vardır — sessiz `catch { }` yasaktır (ARCHITECTURE.md).
enum OraError: Error {
    case permissionDenied(Permission)
    case localeNotInstalled(Locale)
    case modelUnavailable(reason: String)
    case audioWriteFailed(underlying: Error)
    case audioDeviceFailed(stage: String, status: Int32)
    case transcriptionFailed(underlying: Error)
    case contextOverflow
}

extension OraError {

    /// Kullanıcıya gösterilen başlık.
    var turkishMessage: String {
        switch self {
        case .permissionDenied(let permission):
            "\(permission.turkishName) izni verilmedi"
        case .localeNotInstalled(let locale):
            "\(locale.identifier) dil paketi kurulu değil"
        case .modelUnavailable:
            "Apple Intelligence kullanılamıyor"
        case .audioWriteFailed:
            "Ses dosyası yazılamadı"
        case .audioDeviceFailed:
            "Ses aygıtı hazırlanamadı"
        case .transcriptionFailed:
            "Transkripsiyon tamamlanamadı"
        case .contextOverflow:
            "Metin modele sığmadı"
        }
    }

    /// Kullanıcıya gösterilen açıklama + düzeltici eylem.
    var turkishDetail: String {
        switch self {
        case .permissionDenied(let permission):
            switch permission {
            case .microphone:
                "Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon bölümünden ora'ya izin verin."
            case .systemAudio:
                "Sistem Ayarları → Gizlilik ve Güvenlik → Sistem Sesi Kaydı bölümünden ora'ya izin verin. İzin olmadan yalnızca mikrofonunuz kaydedilir."
            case .speechRecognition:
                "Sistem Ayarları → Gizlilik ve Güvenlik → Konuşma Tanıma bölümünden ora'ya izin verin."
            case .calendar:
                "Sistem Ayarları → Gizlilik ve Güvenlik → Takvimler bölümünden ora'ya izin verin."
            }
        case .localeNotInstalled:
            "Dil paketi indirilmeli. Ayarlar'dan indirmeyi başlatabilirsiniz."
        case .modelUnavailable(let reason):
            "Özetleme devre dışı; transkript yine de oluşturulur. (\(reason))"
        case .audioWriteFailed(let underlying):
            "Kayıt diske yazılamadı. Disk alanını kontrol edin.\n\n\(underlying.localizedDescription)"
        case .audioDeviceFailed(let stage, let status):
            "Ses aygıtı kurulurken hata oluştu (\(stage), kod \(status))."
        case .transcriptionFailed(let underlying):
            "Ham ses korundu, daha sonra tekrar deneyebilirsiniz.\n\n\(underlying.localizedDescription)"
        case .contextOverflow:
            "Bu bir hata göstergesidir; metin parçalanarak işlenmeliydi."
        }
    }
}
