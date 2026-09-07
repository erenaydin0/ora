// Çakışan takvim toplantılarında doğru olanı seçme probe'u.
//
// Gerçek `CalendarReader.score` ve `WindowTitle` ile koşar; etkinlikler
// senteticdir (EventKit'e dokunmaz), böylece çakışma senaryosu kurulabilir.
//
//   DD=$(xcodebuild -project ora.xcodeproj -scheme ora -showBuildSettings \
//         | awk -F' = ' '/ BUILD_DIR = /{print $2}')
//   PKG=$(dirname "$(dirname "$DD")")/SourcePackages/checkouts/GRDB.swift
//   xcrun swiftc -o /tmp/takvim -swift-version 6 -target arm64-apple-macos26.0 \
//     -sdk "$(xcrun --show-sdk-path --sdk macosx)" -I "$DD/Debug" \
//     -I "$PKG/Sources/GRDBSQLite" -lsqlite3 "$DD/Debug/GRDB.o" \
//     $(find ora -name '*.swift' ! -name 'oraApp.swift') \
//     "$(dirname "$DD")/Intermediates.noindex/ora.build/Debug/ora.build/DerivedSources/GeneratedAssetSymbols.swift" \
//     probes/takvim_eslestirme.swift && /tmp/takvim
import Foundation

@MainActor var failures = 0
@MainActor func check(_ ok: Bool, _ label: String) {
    print((ok ? "  ✓ " : "  ✗ ") + label)
    if !ok { failures += 1 }
}

func event(_ title: String, start: Date, minutes: Int = 30,
           app: String? = nil, cancelled: Bool = false,
           response: MeetingEvent.Response = .pending,
           organizer: Bool = false, attendees: [String] = []) -> MeetingEvent {
    MeetingEvent(eventID: title, title: title, start: start,
                 end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                 organizer: nil, attendees: attendees, meetingApp: app,
                 isCancelled: cancelled, myStatus: response, organizerIsMe: organizer)
}

let now = Date()
@MainActor func score(_ e: MeetingEvent, app: String? = nil, titles: [String] = []) -> Int {
    CalendarReader.score(e, at: now, app: app, windowTitles: titles).score
}

@main
struct Probe {
    @MainActor static func main() {
        print("1) Pencere başlığı eşleştirme")
        check(CalendarReader.titleMatches("Bordro Fark Çözümü | Microsoft Teams",
                                          "Bordro Fark Çözümü"), "birebir ad, uygulama eki atılıyor")
        check(CalendarReader.titleMatches("Q3 Bütçe Planlama | Microsoft Teams",
                                          "Q3 Bütçe Planlama Toplantısı"), "etkinlik adı daha uzun")
        check(!CalendarReader.titleMatches("Q3 Bütçe Planlama | Microsoft Teams",
                                           "İşe Alım Görüşmesi"), "alakasız toplantı eşleşmiyor")
        check(!CalendarReader.titleMatches("Calendar | Microsoft Teams",
                                           "Bordro Fark Çözümü"), "genel görünüm adı eşleşmiyor")
        check(!CalendarReader.titleMatches("Toplantı | Microsoft Teams",
                                           "Haftalık Toplantı"), "yalnızca gürültü kelimesi yetmiyor")

        print("\n2) Çakışan iki toplantı — aynı anda başlıyor")
        let teams = event("Bordro Fark Çözümü", start: now, app: "com.microsoft.teams2")
        let zoom = event("Tedarikçi Görüşmesi", start: now, app: "us.zoom.xos")
        check(score(teams, app: "com.microsoft.teams2") > score(zoom, app: "com.microsoft.teams2"),
              "mikrofonu Teams tutuyorsa Teams daveti kazanıyor")
        check(score(zoom, app: "us.zoom.xos") > score(teams, app: "us.zoom.xos"),
              "Zoom'da tersi")

        print("\n3) İki Teams toplantısı — uygulama ayırt etmiyor")
        let a = event("Bordro Fark Çözümü", start: now, app: "com.microsoft.teams2",
                      response: .accepted)
        let b = event("Tasarım Değerlendirme", start: now, app: "com.microsoft.teams2",
                      response: .declined)
        check(score(a, app: "com.microsoft.teams2") - score(b, app: "com.microsoft.teams2")
              >= CalendarReader.decisiveMargin,
              "kabul ettiğim, reddettiğimi açık ara geçiyor (soru sorulmaz)")

        let c = event("Tasarım Değerlendirme", start: now, app: "com.microsoft.teams2",
                      response: .accepted)
        let margin = abs(score(a, app: "com.microsoft.teams2") - score(c, app: "com.microsoft.teams2"))
        check(margin < CalendarReader.decisiveMargin,
              "ikisini de kabul ettiysem fark yok → kullanıcıya sorulur (fark \(margin))")
        check(score(c, app: "com.microsoft.teams2",
                    titles: ["Bordro Fark Çözümü | Microsoft Teams"])
              < score(a, app: "com.microsoft.teams2",
                      titles: ["Bordro Fark Çözümü | Microsoft Teams"]) - 2,
              "pencere başlığı gelince belirsizlik kalkıyor")

        print("\n4) Sıralama ve eleme")
        let old = event("Sabahki Toplantı", start: now.addingTimeInterval(-40 * 60))
        check(score(a, app: "com.microsoft.teams2") > score(old), "yeni başlayan öndeki")
        let cancelled = event("İptal Edilmiş", start: now, cancelled: true)
        check(cancelled.isCancelled, "iptal bayrağı okunuyor (aday havuzundan elenir)")

        print("\n5) Gerçek pencere başlıkları (Erişilebilirlik)")
        print("   izin: \(WindowTitle.isAvailable ? "var" : "YOK — sandbox'lı uygulamada beklenen")")
        for app in ["com.microsoft.teams2", "us.zoom.xos"] {
            let titles = WindowTitle.titles(for: app)
            if !titles.isEmpty { print("   \(app): \(titles)") }
        }
        print(failures == 0 ? "\nTÜMÜ GEÇTİ" : "\n\(failures) KONTROL BAŞARISIZ")
        exit(failures == 0 ? 0 : 1)
    }
}
