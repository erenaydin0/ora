import Foundation

/// Toplantı sağlık metrikleri.
///
/// Bunlar **hesaplanır, LLM'e sorulmaz** (ARCHITECTURE.md): zaman damgaları
/// elimizde olduğu için sayı üretmesi için modele başvurmak hem yavaş hem
/// güvenilmezdir.
struct MeetingMetrics: Sendable, Equatable {

    /// Kanal başına konuşma payı, 0…1.
    let talkShare: [Int: Double]
    /// Kimsenin konuşmadığı sürenin toplam kayda oranı, 0…1.
    let deadAirPercentage: Double
    /// Toplam konuşma süresi (saniye).
    let speechDuration: TimeInterval
    /// Kaydın toplam süresi (saniye).
    let totalDuration: TimeInterval

    static func compute(segments: [Segment], duration: TimeInterval) -> MeetingMetrics {
        var perChannel: [Int: TimeInterval] = [:]
        for channel in Channel.allCases {
            perChannel[channel.rawValue] = merged(segments.filter { $0.channel == channel })
        }
        let speech = merged(segments)
        let total = perChannel.values.reduce(0, +)

        var share: [Int: Double] = [:]
        for (channel, seconds) in perChannel {
            share[channel] = total > 0 ? seconds / total : 0
        }
        let deadAir = duration > 0 ? max(0, (duration - speech) / duration) : 0
        return MeetingMetrics(talkShare: share, deadAirPercentage: deadAir,
                              speechDuration: speech, totalDuration: duration)
    }

    /// Üst üste binen aralıklar bir kez sayılır — iki kişi aynı anda konuşurken
    /// toplam konuşma süresi kaydın süresini aşmamalı.
    private static func merged(_ segments: [Segment]) -> TimeInterval {
        let ranges = segments.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval = 0
        for (start, end) in ranges where end > start {
            if let openStart = currentStart {
                if start <= currentEnd {
                    currentEnd = max(currentEnd, end)
                } else {
                    total += currentEnd - openStart
                    currentStart = start
                    currentEnd = end
                }
            } else {
                currentStart = start
                currentEnd = end
            }
        }
        if let openStart = currentStart { total += currentEnd - openStart }
        return total
    }
}
