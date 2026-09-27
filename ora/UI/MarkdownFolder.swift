import Foundation

/// Özet hazır olunca notu kullanıcının seçtiği klasöre Markdown olarak
/// yazar — Obsidian, iCloud Drive ya da herhangi bir not klasörü
/// (COMPETITION.md §4.12'nin bağlantısız kısmı).
///
/// **Ağ kullanmaz**: dosya diske yazılır. Ama klasör iCloud Drive ya da bir
/// bulut sağlayıcısının eşitlediği klasörse dosya oradan eşitlenir; bu yüzden
/// "cihazdan çıkmasın" işaretli toplantı **hiçbir klasöre yazılmaz** ve
/// Ayarlar eşitlenen klasörü açıkça söyler.
enum MarkdownFolder {

    /// Klasör bir bulut eşitlemesinin içinde mi? iCloud Drive
    /// (`Library/Mobile Documents`) ve File Provider klasörleri
    /// (`Library/CloudStorage` — Dropbox, Google Drive, OneDrive).
    static func isSynced(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }

    /// Dosyanın içeriği: künye (YAML) + dışa aktarımın Markdown'ı. Künye
    /// Obsidian'da etiket ve tarih olarak okunur.
    static func document(_ payload: MeetingExport.Payload, meetingID: Int64,
                         tags: [String], includeTranscript: Bool) -> String {
        var front = ["---", "ora: \(meetingID)",
                     "tarih: \(payload.date.formatted(.iso8601.year().month().day()))"]
        if !tags.isEmpty {
            front.append("tags: [" + tags.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
                .joined(separator: ", ") + "]")
        }
        front.append("---")
        return front.joined(separator: "\n") + "\n\n"
            + MeetingExport.markdown(payload, includeTranscript: includeTranscript)
    }

    /// Yazar ve dosyanın yerini döndürür. Aynı tarih ve başlıkla yeniden
    /// özetlenen toplantı aynı dosyanın üstüne yazılır.
    @discardableResult
    static func write(_ payload: MeetingExport.Payload, meetingID: Int64, tags: [String],
                      to folder: URL, includeTranscript: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: MeetingExport.fileName(payload) + ".md",
                                   directoryHint: .notDirectory)
        try document(payload, meetingID: meetingID, tags: tags,
                     includeTranscript: includeTranscript)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
