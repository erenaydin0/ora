import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Dışa aktarım: Markdown, PDF ve panoya e-posta taslağı.
/// Hiçbiri ağ kullanmaz — dosya diske yazılır, taslak panoya kopyalanır.
enum MeetingExport {

    struct Payload {
        let title: String
        let date: Date
        let duration: Int
        let segments: [Segment]
        let summary: Ozet?
        let topics: [TopicSegment]
        let actions: [MeetingAction]
        let participants: [String]
    }

    // MARK: - Markdown

    /// Yapı `circleback-notes/` referansından: başlık, künye, aksiyonlar
    /// (onay kutulu), genel bakış ve konu bölümleri. Transkript en sonda ve
    /// isteğe bağlı — notu okunur kılan şey onun ayrı durması.
    static func markdown(_ payload: Payload, includeTranscript: Bool = true) -> String {
        var lines: [String] = []
        lines.append("# \(payload.title)")
        lines.append("")
        lines.append("**Tarih**: \(longDate(payload.date))  ")
        lines.append("**Süre**: \(durationText(payload.duration))  ")
        if !payload.participants.isEmpty {
            lines.append("**Kişiler**: \(list(payload.participants))")
        }
        lines.append("")

        if !payload.actions.isEmpty {
            lines.append("#### Aksiyonlar")
            lines.append("")
            for action in payload.actions {
                var line = "- [\(action.isDone ? "x" : " ")] "
                if isSpecified(action.person) { line += "\(action.person) — " }
                line += "**\(action.task)**"
                if let context = action.context, !context.isEmpty { line += " \(context)" }
                if let deadline = action.deadline, !deadline.isEmpty {
                    line += " _(\(deadline))_"
                }
                lines.append(line)
            }
            lines.append("")
        }

        if let summary = payload.summary {
            if !summary.genelBakis.isEmpty {
                lines.append("#### Genel Bakış")
                lines.append("")
                summary.genelBakis.forEach { lines.append("- \($0)") }
                lines.append("")
            }
            if !summary.kararlar.isEmpty {
                lines.append("#### Kararlar")
                lines.append("")
                summary.kararlar.forEach { lines.append("- \($0)") }
                lines.append("")
            }
        }

        for topic in payload.topics where !topic.bullets.isEmpty {
            lines.append("#### \(topic.title)")
            lines.append("")
            topic.bullets.forEach { lines.append("- \($0)") }
            lines.append("")
        }

        if includeTranscript, !payload.segments.isEmpty {
            lines.append("#### Transkript")
            lines.append("")
            for segment in payload.segments {
                lines.append("**\(segment.speaker)** `\(segment.timeLabel)`  ")
                lines.append(segment.text)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Panoya kopyalanan e-posta taslağı — özet odaklı, transkript içermez.
    static func emailDraft(_ payload: Payload) -> String {
        var lines: [String] = []
        lines.append("Konu: \(payload.title)")
        lines.append("")
        lines.append("Merhaba,")
        lines.append("")
        if let summary = payload.summary, !summary.genelBakis.isEmpty {
            summary.genelBakis.forEach { lines.append("• \($0)") }
            lines.append("")
            if !summary.kararlar.isEmpty {
                lines.append("Kararlar:")
                summary.kararlar.forEach { lines.append("• \($0)") }
                lines.append("")
            }
        } else if payload.actions.isEmpty {
            lines.append("Toplantının transkripti hazır, özet oluşturulamadı.")
            lines.append("")
        }
        if !payload.actions.isEmpty {
            lines.append("Aksiyonlar:")
            for action in payload.actions {
                var line = "• "
                if isSpecified(action.person) { line += "\(action.person): " }
                line += action.task
                if let deadline = action.deadline, !deadline.isEmpty { line += " (\(deadline))" }
                lines.append(line)
                if let context = action.context, !context.isEmpty {
                    lines.append("  \(context)")
                }
            }
            lines.append("")
        }
        lines.append("İyi çalışmalar.")
        return lines.joined(separator: "\n")
    }

    /// "belirtilmedi" bir kişi adı değil — çıktıda yer kaplamaz.
    static func isSpecified(_ person: String) -> Bool {
        !person.trimmingCharacters(in: .whitespaces).isEmpty
            && person.lowercased(with: Locale(identifier: "tr_TR")) != "belirtilmedi"
    }

    /// "a, b ve c" — Türkçe bağlaçla.
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " ve " + names[names.count - 1]
    }

    static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "EEEE, d MMMM yyyy HH:mm"
        return formatter.string(from: date)
    }

    @MainActor
    static func copyEmailDraft(_ payload: Payload) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(emailDraft(payload), forType: .string)
    }

    // MARK: - Dosyaya yazma

    @MainActor
    static func saveMarkdown(_ payload: Payload) {
        guard let url = savePanel(name: fileName(payload) + ".md", type: .plainText) else { return }
        do {
            try markdown(payload).write(to: url, atomically: true, encoding: .utf8)
            Log.info(.ui, "Markdown dışa aktarıldı: \(url.lastPathComponent)")
        } catch {
            Log.error(.ui, "Markdown yazılamadı", error)
        }
    }

    @MainActor
    static func savePDF(_ payload: Payload) {
        guard let url = savePanel(name: fileName(payload) + ".pdf", type: .pdf) else { return }
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4, 72 dpi
        let renderer = ImageRenderer(content: ExportDocument(payload: payload)
            .frame(width: page.width))
        renderer.proposedSize = ProposedViewSize(width: page.width, height: nil)

        var box = page
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return }

        renderer.render { size, draw in
            // Uzun içerik tek sayfaya sığmaz; sayfa sayfa kaydırılarak çizilir.
            let pageCount = max(1, Int((size.height / page.height).rounded(.up)))
            for index in 0 ..< pageCount {
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(index) * page.height
                                    - (size.height - page.height))
                draw(context)
                context.restoreGState()
                context.endPDFPage()
            }
            context.closePDF()
        }
        Log.info(.ui, "PDF dışa aktarıldı: \(url.lastPathComponent)")
    }

    @MainActor
    private static func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func fileName(_ payload: Payload) -> String {
        let stamp = payload.date.formatted(.iso8601.year().month().day())
        let safe = payload.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp) \(safe)"
    }

    private static func durationText(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60) dk \(seconds % 60) sn" : "\(seconds) sn"
    }
}

/// PDF'e çizilen belge. Ekran arayüzü değil, basılı sayfa düzeni.
private struct ExportDocument: View {
    let payload: MeetingExport.Payload

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(payload.title)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.oraInk)
            Text(MeetingExport.longDate(payload.date))
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
            if !payload.participants.isEmpty {
                Text(MeetingExport.list(payload.participants))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !payload.actions.isEmpty {
                block("Aksiyonlar") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(payload.actions) { action in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(action.isDone ? "☑" : "☐") \(actionLine(action))")
                                    .font(.system(size: 12))
                                if let context = action.context, !context.isEmpty {
                                    Text(context)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.oraInkMuted)
                                }
                            }
                        }
                    }
                }
            }
            if let summary = payload.summary {
                if !summary.genelBakis.isEmpty {
                    block("Genel bakış") { bullets(summary.genelBakis) }
                }
                if !summary.kararlar.isEmpty {
                    block("Kararlar") { bullets(summary.kararlar) }
                }
            }
            // Konular PDF'te hiç yoktu — notun gövdesi basılı çıktıda eksikti.
            ForEach(payload.topics) { topic in
                if !topic.bullets.isEmpty {
                    block(topic.title) { bullets(topic.bullets) }
                }
            }
            if !payload.segments.isEmpty {
                block("Transkript") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(payload.segments) { segment in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(segment.speaker) · \(segment.timeLabel)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.oraInkMuted)
                                Text(segment.text).font(.system(size: 11))
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(Color.oraInk)
        .padding(48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.oraSurface)
    }

    private func actionLine(_ action: MeetingAction) -> String {
        var line = MeetingExport.isSpecified(action.person) ? "\(action.person): " : ""
        line += action.task
        if let deadline = action.deadline, !deadline.isEmpty { line += " — \(deadline)" }
        return line
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)").font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func block<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .kerning(0.6)
                .foregroundStyle(Color.oraInkMuted)
            content()
        }
    }
}
