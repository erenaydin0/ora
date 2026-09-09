import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// İçe aktarmanın arayüz yüzeyi: dosya seçiciler ve yapıştırma sayfası.
///
/// Dışa aktarımla (`MeetingExport`) aynı biçim: panel senkron açılır
/// (`runModal`), sonucu çağıran işler. Uygulama sandbox'lı değil (§29.4),
/// bu yüzden güvenlik kapsamlı yer imi gerekmez — seçilen dosya doğrudan
/// okunur ve **kaynağa dokunulmaz**, kopyası alınır.
enum MeetingImportPanel {

    static func pickAudio() -> URL? {
        panel(title: "İçe aktarılacak ses kaydını seçin",
              prompt: "İçe aktar",
              types: AudioImport.contentTypes,
              extensions: AudioImport.fileExtensions)
    }

    static func pickTranscript() -> URL? {
        panel(title: "İçe aktarılacak transkript dosyasını seçin",
              prompt: "İçe aktar",
              types: [.plainText, .text, .utf8PlainText,
                      UTType(filenameExtension: "vtt"),
                      UTType(filenameExtension: "srt")].compactMap { $0 },
              extensions: MeetingImporter.transcriptExtensions)
    }

    /// - Parameter extensions: sistemde kayıtlı bir tür karşılığı olmayan
    ///   uzantılar (`.vtt`, `.srt`, bazı makinelerde `.opus`) listeye dinamik
    ///   tür olarak eklenir; yoksa dosya seçicide sönük görünür ve kullanıcı
    ///   elindeki dökümü seçemez.
    private static func panel(title: String, prompt: String,
                              types: [UTType], extensions: Set<String>) -> URL? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.prompt = prompt
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types + extensions.compactMap {
            UTType(filenameExtension: $0)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Transkripti **yapıştırarak** içe alma. Kullanıcının elindeki döküm çoğu
/// zaman bir dosya değil, panodaki metindir (Teams'in "transkripti kopyala"sı,
/// bir e-postadan seçilen bölüm).
///
/// Biçim dayatılmaz: ne varsa yapıştırılır, `TranscriptParser` konuşmacıyı ve
/// zaman damgasını tanıyabildiği kadar tanır. Bu yüzden altta ne beklendiğini
/// **söyleyen** tek satır var; boş bir kutu kullanıcıya biçim tahmin ettirir.
struct PasteTranscriptSheet: View {

    @Binding var text: String
    let isBusy: Bool
    let importAction: () -> Void
    let cancel: () -> Void

    @FocusState private var focused: Bool

    private var canImport: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkripti yapıştırın")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)

            Text("Teams veya Zoom dökümü, altyazı dosyasının içeriği ya da düz metin. "
                 + "“Ayşe: …” biçimindeki satırlar konuşmacı olarak, "
                 + "“[00:12:30]” gibi damgalar zaman olarak okunur.")
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.oraInk)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 240)
                .background(Color.oraPaper)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.oraBorder))
                .focused($focused)
                .disabled(isBusy)

            HStack {
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
                Spacer()
                Button("Vazgeç", action: cancel)
                Button("İçe aktar", action: importAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Color.oraChrome)
        .onExitCommand(perform: cancel)
        .task { focused = true }
    }

    private var countLabel: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Henüz metin yok" }
        let lines = trimmed.split(separator: "\n").count
        return "\(lines) satır · \(trimmed.count) karakter"
    }
}

#Preview("Transkript yapıştırma") {
    PasteTranscriptSheet(text: .constant("""
        Ayşe: Bordro çalışmasında son durum ne?
        Mehmet: Matrahlar hazır, işsizlik kesintisi kaldı.
        """), isBusy: false, importAction: {}, cancel: {})
}
