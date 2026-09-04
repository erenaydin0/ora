import SwiftUI

/// Özet sekmesi: genel bakış, kararlar, aksiyonlar, konu blokları ve
/// **hesaplanmış** sağlık metrikleri (LLM'e sorulmaz).
struct SummaryView: View {

    let summary: Ozet?
    let topics: [TopicSegment]
    let metrics: MeetingMetrics?
    let notice: String?

    var body: some View {
        if summary == nil && notice == nil && metrics == nil {
            EmptyState(icon: "sparkles",
                       title: "Özet hazır değil",
                       detail: "Özetleme kayıt bittikten sonra çalışır.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let notice {
                        Notice(text: notice)
                    }
                    if let summary {
                        Section("Genel bakış") {
                            Text(summary.genelBakis)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.oraInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if !summary.kararlar.isEmpty {
                            Section("Kararlar") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(summary.kararlar.enumerated()), id: \.offset) { _, karar in
                                        Bullet(text: karar)
                                    }
                                }
                            }
                        }
                        if !summary.aksiyonlar.isEmpty {
                            Section("Aksiyonlar") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(summary.aksiyonlar) { ActionRow(action: $0) }
                                }
                            }
                        }
                    }
                    if let metrics {
                        Section("Toplantı") { MetricsCard(metrics: metrics) }
                    }
                    if !topics.isEmpty {
                        Section("Konular") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(topics) { topic in
                                    HStack(spacing: 10) {
                                        Text(topic.timeLabel)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(Color.oraInkMuted)
                                        Text(topic.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.oraInk)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func Section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .medium))
                .kerning(0.6)
                .foregroundStyle(Color.oraInk)
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
                .foregroundStyle(Color.oraInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct ActionRow: View {
    let action: Ozet.Aksiyon

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(action.kisi)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.oraBlue)
                if action.sonTarih.lowercased(with: Locale(identifier: "tr_TR")) != "belirtilmedi" {
                    Text(action.sonTarih)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                }
            }
            Text(action.gorev)
                .font(.system(size: 14))
                .foregroundStyle(Color.oraInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oraCard()
    }
}

/// Konuşma payı ve ölü hava — zaman damgalarından hesaplanır.
private struct MetricsCard: View {
    let metrics: MeetingMetrics

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(Channel.allCases, id: \.rawValue) { channel in
                Stat(label: channel.speaker,
                     value: percent(metrics.talkShare[channel.rawValue] ?? 0))
            }
            Stat(label: "Ölü hava", value: percent(metrics.deadAirPercentage))
            Stat(label: "Süre", value: durationText)
            Spacer()
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
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .oraCard()
    }
}
