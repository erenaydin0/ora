import Foundation

/// Kümeleri bilinen kişilerin ses izleriyle eşleştirir — **tutucu**.
///
/// Eşikler Anarlog'dan (eski Hyprnote, `crates/voiceprint/src/matching.rs`):
/// aynı model ailesi (WeSpeaker ResNet34 gömmesi) üzerinde çalışıyorlar.
/// ora'nın kendi ses zincirinde ölçülmedi (RESEARCH.md §40).
///
/// Bir küme bir kişiye ancak üç koşul **birlikte** sağlanırsa adlandırılır:
///  1. benzerlik ≥ `minimumScore`,
///  2. kümenin en iyi adayı ikincisini `minimumMargin` kadar geçiyor,
///  3. kişinin de en iyi kümesi bu küme ve o da ikincisini aynı farkla geçiyor.
/// Üçüncüsü aynı kişinin iki kümeye birden verilmesini önler. Emin
/// olunamayan küme "Katılımcı N" kalır — kendinden emin yanlış bir ad,
/// numaralı bir etiketten kötüdür.
nonisolated enum VoiceMatcher {

    static let minimumScore: Float = 0.62
    static let minimumMargin: Float = 0.08

    /// - Returns: küme → kişi.
    static func assign(clusters: [String: [Float]],
                       people: [String: [[Float]]]) -> [String: String] {
        let references = people.compactMapValues(centroid)
        guard !clusters.isEmpty, !references.isEmpty else { return [:] }

        var scores: [(cluster: String, person: String, score: Float)] = []
        for (cluster, embedding) in clusters {
            for (person, reference) in references {
                if let score = cosine(embedding, reference) {
                    scores.append((cluster, person, score))
                }
            }
        }

        var result: [String: String] = [:]
        for cluster in clusters.keys {
            let forCluster = scores.filter { $0.cluster == cluster }
                .sorted { $0.score > $1.score }
            guard let best = forCluster.first,
                  isUnique(best.score, second: forCluster.dropFirst().first?.score)
            else { continue }
            let forPerson = scores.filter { $0.person == best.person }
                .sorted { $0.score > $1.score }
            guard forPerson.first?.cluster == cluster,
                  isUnique(best.score, second: forPerson.dropFirst().first?.score)
            else { continue }
            result[cluster] = best.person
        }
        return result
    }

    private static func isUnique(_ best: Float, second: Float?) -> Bool {
        best >= minimumScore && best - (second ?? -1) >= minimumMargin
    }

    /// Kişinin örneklerinin birim vektörlerinin ortalaması.
    static func centroid(_ samples: [[Float]]) -> [Float]? {
        let normalized = samples.compactMap(unit)
        guard let first = normalized.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for sample in normalized where sample.count == sum.count {
            for index in sum.indices { sum[index] += sample[index] }
        }
        return unit(sum)
    }

    static func unit(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    static func cosine(_ left: [Float], _ right: [Float]) -> Float? {
        guard left.count == right.count, !left.isEmpty,
              let a = unit(left), let b = unit(right) else { return nil }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
