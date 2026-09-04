import SwiftUI

/// Özet sekmesi: genel bakış, kararlar, aksiyonlar, konu blokları ve
/// **hesaplanmış** sağlık metrikleri (LLM'e sorulmaz).
struct SummaryView: View {

    let summary: Ozet?
    let topics: [TopicSegment]
    let metrics: MeetingMetrics?
    let notice: String?
    /// Takvimden gelen katılımcılar. Takvim kapalıysa boş ve **yer tutmaz**.
    var calendarParticipants: [String] = []
    /// Güç/termal nedeniyle ertelendiyse kullanıcı elle başlatabilir.
    var onSummarizeNow: (() -> Void)?

    var body: some View {
        if summary == nil && notice == nil && metrics == nil {
            EmptyState(icon: "sparkles",
                       title: "Özet hazır değil",
                       detail: "Özetleme kayıt bittikten sonra çalışır.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let notice {
                        Notice(text: notice, action: onSummarizeNow)
                    }
                    if let summary {
                        Section("Genel bakış") {
                            // Tek blok metin: satır arası açık, satır uzunluğu
                            // sınırlı — özet okunacak metindir, veri değil.
                            Text(summary.genelBakis)
                                .font(.system(size: 14))
                                .lineSpacing(OraStyle.bodyLineSpacing)
                                .foregroundStyle(Color.oraInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if !summary.kararlar.isEmpty {
                            Section("Kararlar") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(summary.kararlar.enumerated()), id: \.offset) { _, karar in
                                        Bullet(text: karar)
                                    }
                                }
                            }
                        }
                        if !summary.aksiyonlar.isEmpty {
                            Section("Aksiyonlar") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(summary.aksiyonlar) { ActionRow(action: $0) }
                                }
                            }
                        }
                    }
                    if let metrics {
                        Section("Toplantı") {
                            MetricsCard(metrics: metrics,
                                        calendarParticipants: calendarParticipants)
                        }
                    }
                    if !topics.isEmpty {
                        Section("Konular") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(topics) { topic in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(topic.timeLabel)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(Color.oraInkMuted)
                                        Text(topic.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.oraInk)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: OraStyle.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func Section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Bölüm etiketi küçük, uppercase ve ikincil: içeriğin önüne geçmez.
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Color.oraInkMuted)
            content()
        }
    }
}

private struct Bullet: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(OraStyle.bodyLineSpacing - 1)
                .foregroundStyle(Color.oraInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Aksiyon **yapılacak iş listesi değildir** — toplantıdan çıkarılmış bir
/// bilgidir. Bu yüzden onay kutusu, durum veya ilerleme göstergesi yok:
/// önce iş cümlesi, altında düşük kontrastlı üstlenen/son tarih bilgisi.
private struct ActionRow: View {
    let action: Ozet.Aksiyon
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(action.gorev)
                .font(.system(size: 14))
                .lineSpacing(OraStyle.bodyLineSpacing - 1)
                .foregroundStyle(Color.oraInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(metadataLine)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oraQuietCard(hovered: isHovered)
        .onHover { hovering in
            withAnimation(OraStyle.transition) { isHovered = hovering }
        }
    }

    /// "Atanan kişi: …" — belirtilmemiş olması da bir bilgidir, ama vurgulanmaz.
    private var metadataLine: String {
        var parts = ["Atanan kişi: \(sentenceCased(action.kisi))"]
        if isSpecified(action.sonTarih) {
            parts.append("Son tarih: \(sentenceCased(action.sonTarih))")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func isSpecified(_ value: String) -> Bool {
        value.lowercased(with: Self.turkish) != "belirtilmedi"
            && !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Model alanları küçük harfle dönebiliyor ("ben", "belirtilmedi").
    /// Türkçe locale ile büyütülür — aksi hâlde "i" → "I" olurdu.
    private func sentenceCased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased(with: Self.turkish) + value.dropFirst()
    }

    private static let turkish = Locale(identifier: "tr_TR")
}

/// Konuşma payı ve ölü hava — zaman damgalarından hesaplanır.
private struct MetricsCard: View {
    let metrics: MeetingMetrics
    var calendarParticipants: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(Channel.allCases, id: \.rawValue) { channel in
                    Stat(label: channel.speaker,
                         value: percent(metrics.talkShare[channel.rawValue] ?? 0))
                }
                Stat(label: "Ölü hava", value: percent(metrics.deadAirPercentage))
                Stat(label: "Süre", value: durationText)
                Spacer()
            }
            // Davetli ve konuşan ayrımı toplantının kimin için yapıldığını söyler.
            if !calendarParticipants.isEmpty {
                Divider().overlay(Color.oraBorder)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.oraInkMuted)
                        Text("davetli \(calendarParticipants.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.oraInkMuted)
                    }
                    Text(calendarParticipants.joined(separator: ", "))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.oraInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oraCard()
    }

    private var durationText: String {
        let total = Int(metrics.totalDuration)
        return total >= 60 ? "\(total / 60) dk" : "\(total) sn"
    }

    private func percent(_ value: Double) -> String { "%\(Int((value * 100).rounded()))" }

    private struct Stat: View {
        let label: String
        let value: String
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
            }
        }
    }
}

/// Özet neden yok — sessiz başarısızlık yok.
private struct Notice: View {
    let text: String
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action {
                Button("Şimdi özetle", action: action)
            }
        }
        .padding(12)
        .oraCard()
    }
}
