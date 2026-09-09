import Foundation
import GRDB

/// İçe aktarmanın veritabanı kapısı.
///
/// Ayrı dosyada: içe aktarma `meetings` satırını kayıttan **farklı** açar ve
/// bu farkın gerekçesi burada, kullanıldığı yerin yanında duruyor.
nonisolated extension MeetingStore {

    /// İçe aktarılan toplantı satırı.
    ///
    /// `createMeeting`'den iki farkı var:
    /// - Durum doğrudan `processing`. İçe aktarmada "kayıt sürüyor" hâli yok;
    ///   satır açıldığı anda işlenmeyi bekliyor demektir.
    /// - Başlık kaynaktan gelir (dosya adı). Geçicidir: hat transkriptten bir
    ///   başlık üretirse onun yerini alır — başlık önceliği değişmedi
    ///   (takvim → üretilen → tarih/saat).
    ///
    /// - Parameter duration: transkript içe aktarımında son repliğin bitişi;
    ///   ses içe aktarımında dosya çevrildikten sonra `markProcessing` yazar.
    func createImportedMeeting(title: String, date: Date,
                               duration: TimeInterval = 0) async throws -> Int64 {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await database.write { db in
            var record = MeetingRecord(
                id: nil,
                title: trimmed.isEmpty ? Self.provisionalTitle(for: date) : trimmed,
                date: date, duration: Int(duration.rounded()),
                status: MeetingRecord.Status.processing.rawValue,
                template: "general", audioPath: nil,
                calendarEventId: nil, createdAt: Date())
            try record.insert(db)
            return record.id!
        }
    }
}
