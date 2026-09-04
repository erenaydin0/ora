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
        let metrics: MeetingMetrics?
    }

    // MARK: - Markdown

    static func markdown(_ payload: Payload) -> String {
        var lines: [String] = []
        lines.append("# \(payload.title)")
        lines.append("")
        lines.append(payload.date.formatted(date: .long, time: .shortened)
                     + " · " + durationText(payload.duration))
        lines.append("")

        if let summary = payload.summary {
            lines.append("## Genel bakış")
            lines.append("")
            lines.append(summary.genelBakis)
            lines.append("")
            if !summary.kararlar.isEmpty {
                lines.append("## Kararlar")
                lines.append("")
                summary.kararlar.forEach { lines.append("- \($0)") }
                lines.append("")
            }
            if !summary.aksiyonlar.isEmpty {
                lines.append("## Aksiyonlar")
                lines.append("")
                lines.append("| Kişi | Görev | Son tarih |")
                lines.append("|---|---|---|")
                for aksiyon in summary.aksiyonlar {
                    lines.append("| \(aksiyon.kisi) | \(aksiyon.gorev) | \(aksiyon.sonTarih) |")
                }
                lines.append("")
            }
        }

        if let metrics = payload.metrics {
            lines.append("## Toplantı")
            lines.append("")
            for channel in Channel.allCases {
                let share = Int(((metrics.talkShare[channel.rawValue] ?? 0) * 100).rounded())
                lines.append("- \(channel.speaker): %\(share)")
            }
            lines.append("- Ölü hava: %\(Int((metrics.deadAirPercentage * 100).rounded()))")
            lines.append("")
        }

        if !payload.topics.isEmpty {
            lines.append("## Konular")
            lines.append("")
            payload.topics.forEach { lines.append("- `\($0.timeLabel)` \($0.title)") }
            lines.append("")
        }

        if !payload.segments.isEmpty {
            lines.append("## Transkript")
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
        if let summary = payload.summary {
            lines.append(summary.genelBakis)
            lines.append("")
            if !summary.kararlar.isEmpty {
                lines.append("Kararlar:")
                summary.kararlar.forEach { lines.append("• \($0)") }
                lines.append("")
            }
            if !summary.aksiyonlar.isEmpty {
                lines.append("Aksiyonlar:")
                for aksiyon in summary.aksiyonlar {
                    let deadline = MeetingStore.normalizedDeadline(aksiyon.sonTarih)
                        .map { " (\($0))" } ?? ""
                    lines.append("• \(aksiyon.kisi): \(aksiyon.gorev)\(deadline)")
                }
                lines.append("")
            }
        } else {
            lines.append("Toplantının transkripti hazır, özet oluşturulamadı.")
            lines.append("")
        }
        lines.append("İyi çalışmalar.")
        return lines.joined(separator: "\n")
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
            Text(payload.date.formatted(date: .long, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)

            if let summary = payload.summary {
                block("Genel bakış") {
                    Text(summary.genelBakis).font(.system(size: 12))
                }
                if !summary.kararlar.isEmpty {
                    block("Kararlar") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(summary.kararlar.enumerated()), id: \.offset) { _, karar in
                                Text("• \(karar)").font(.system(size: 12))
                            }
                        }
                    }
                }
                if !summary.aksiyonlar.isEmpty {
                    block("Aksiyonlar") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(summary.aksiyonlar) { aksiyon in
                                Text("• \(aksiyon.kisi): \(aksiyon.gorev) — \(aksiyon.sonTarih)")
                                    .font(.system(size: 12))
                            }
                        }
                    }
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
