import Foundation

/// Toplantı şablonu (COMPETITION.md §4.7). `meetings.template` sütununda durur.
///
/// **Şablon şemayı değiştirmez**, talimatı değiştirir: modele toplantının ne
/// tür olduğu söylenir ve `kararlar` alanının o toplantıda neyi taşıdığı
/// yeniden tanımlanır (bire birde geri bildirim, mülakatta aday hakkında
/// söylenenler). Arayüz bölümün adını buna göre değiştirir.
///
/// **Genel ölçülmüş olandır ve varsayılandır:** o şablonda bütün istem
/// parçaları ya boştur ya da eski metnin bayt bayt aynısıdır
/// (`TemplateTests`). Diğer şablonlar **ölçülmedi**; §35'in kapsama puanıyla
/// değerlendirilmeden hiçbiri varsayılan yapılmaz.
nonisolated enum MeetingTemplate: String, CaseIterable, Sendable, Identifiable {
    case general
    case oneOnOne = "one_on_one"
    case customer
    case sprint
    case interview

    var id: String { rawValue }

    init(stored: String?) {
        self = stored.flatMap(MeetingTemplate.init(rawValue:)) ?? .general
    }

    var turkishName: String {
        switch self {
        case .general:   "Genel"
        case .oneOnOne:  "Bire bir"
        case .customer:  "Müşteri görüşmesi"
        case .sprint:    "Ürün / sprint"
        case .interview: "Mülakat"
        }
    }

    /// Özet'te `kararlar` bölümünün adı.
    var decisionsTitle: String {
        switch self {
        case .general, .sprint: "Kararlar"
        case .oneOnOne:         "Geri bildirim ve gelişim"
        case .customer:         "Müşterinin talepleri"
        case .interview:        "Aday hakkında öne çıkanlar"
        }
    }

    // MARK: Apple motoru (map-reduce, İngilizce istem)

    /// Parça istemine eklenen cümle. Genel'de **boş**.
    var chunkFocus: String {
        switch self {
        case .general:
            ""
        case .oneOnOne:
            " This is a one-on-one meeting: capture feedback, personal goals, "
                + "blockers and the support that was agreed."
        case .customer:
            " This is a customer meeting: capture the customer's needs, objections, "
                + "budget, timeline and the next steps that were agreed."
        case .sprint:
            " This is a product or sprint meeting: capture scope, priorities, "
                + "estimates, risks and blockers."
        case .interview:
            " This is a job interview: capture the candidate's experience, skills "
                + "and answers to the key questions. Do not judge the candidate; "
                + "write only what was said."
        }
    }

    /// Birleştirme isteminde toplantının türü. Genel'de **boş**.
    var reduceFocus: String {
        switch self {
        case .general:   ""
        case .oneOnOne:  " This is a one-on-one meeting."
        case .customer:  " This is a customer meeting."
        case .sprint:    " This is a product or sprint meeting."
        case .interview: " This is a job interview."
        }
    }

    /// Birleştirme isteminde kararların kuralı. Genel ve sprint'te ölçülen
    /// metnin **aynısıdır**.
    var decisionRules: String {
        switch self {
        case .general, .sprint:
            """
            - A decision is something the group settled on; a subject
              heading or a topic name is not a decision.
            - Write as decisions only things that were actually decided;
              if nothing was decided, leave the list empty.
            """
        case .oneOnOne:
            """
            - In the decisions list write the feedback that was given and
              the development points that were agreed; if there were none,
              leave the list empty.
            """
        case .customer:
            """
            - In the decisions list write what the customer asked for or
              objected to, with budget and timeline if they were stated; if
              there were none, leave the list empty.
            """
        case .interview:
            """
            - In the decisions list write the strengths and concerns about
              the candidate that the interviewers stated; never add your own
              judgement.
            """
        }
    }

    // MARK: Yerel ve bağlı motor (tek geçiş, Türkçe istem)

    /// Genel'de **boş**.
    var localFocus: String {
        switch self {
        case .general:
            ""
        case .oneOnOne:
            " Bu bir bire bir görüşme: geri bildirimi, kişisel hedefleri, engelleri ve "
                + "üzerinde anlaşılan desteği yakala."
        case .customer:
            " Bu bir müşteri görüşmesi: müşterinin ihtiyaçlarını, itirazlarını, bütçesini, "
                + "zamanlamasını ve üzerinde anlaşılan sonraki adımları yakala."
        case .sprint:
            " Bu bir ürün / sprint toplantısı: kapsamı, öncelikleri, tahminleri, riskleri "
                + "ve engelleri yakala."
        case .interview:
            " Bu bir iş görüşmesi: adayın deneyimini, becerilerini ve temel sorulara "
                + "verdiği yanıtları yakala. Adayı sen değerlendirme; yalnızca söyleneni yaz."
        }
    }

    /// Genel ve sprint'te ölçülen kuralın **aynısıdır**.
    var localDecisionRule: String {
        switch self {
        case .general, .sprint:
            "- Karar, grubun üzerinde anlaştığı şeydir; konu başlığı karar değildir."
        case .oneOnOne:
            "- \"decisions\" listesine verilen geri bildirimi ve üzerinde anlaşılan "
                + "gelişim noktalarını yaz; yoksa boş bırak."
        case .customer:
            "- \"decisions\" listesine müşterinin talep ettiklerini ve itiraz ettiklerini "
                + "yaz, söylendiyse bütçe ve zamanlamayla; yoksa boş bırak."
        case .interview:
            "- \"decisions\" listesine görüşmecilerin aday hakkında söylediği güçlü "
                + "yanları ve çekinceleri yaz; kendi yargını ekleme."
        }
    }

    // MARK: Takvimden tahmin

    /// Takvim etkinliğinin adından şablon **önerisi**. Bulamazsa `nil` —
    /// toplantı Genel kalır. Yalnızca şablon henüz Genel'ken uygulanır ve
    /// kullanıcı başlıktaki seçiciden değiştirir.
    static func guess(from title: String) -> MeetingTemplate? {
        let key = " " + title.lowercased(with: Locale(identifier: "tr_TR")) + " "
        func has(_ words: [String]) -> Bool { words.contains { key.contains($0) } }
        if has(["1:1", "1-1", "1on1", "1 on 1", "one on one", "one-on-one",
                "birebir", "bire bir"]) { return .oneOnOne }
        if has(["mülakat", "interview", "aday görüşmesi"]) { return .interview }
        if has(["sprint", "standup", "stand-up", "daily", "retro", "planning",
                "planlama", "grooming", "refinement"]) { return .sprint }
        if has(["müşteri", "customer", "client", "demo "]) { return .customer }
        return nil
    }
}
