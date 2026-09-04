import Foundation
import EventKit

// Varsayılan: yalnızca durum okur, İZİN İSTEMEZ.
// İzin istemek ve gerçek etkinlik okumak için:  ./calendar --request
let wantsRequest = CommandLine.arguments.contains("--request")

let names: [EKAuthorizationStatus: String] = [
  .notDetermined: "notDetermined (henüz sorulmadı)", .restricted: "restricted",
  .denied: "denied", .fullAccess: "fullAccess", .writeOnly: "writeOnly"
]
let st = EKEventStore.authorizationStatus(for: .event)
print("Takvim yetki durumu: \(names[st] ?? "\(st)")")

guard wantsRequest else {
  print("→ izin istemi tetiklenmedi. Gerçek veriyi görmek için: ./calendar --request")
  exit(0)
}

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
store.requestFullAccessToEvents { ok, err in
  granted = ok; if let e = err { print("hata: \(e)") }; sem.signal()
}
sem.wait()
guard granted else { print("izin verilmedi"); exit(1) }

print("\n=== Takvimler ===")
for c in store.calendars(for: .event) {
  print("  \(c.title)  [\(c.source.title)]  düzenlenebilir: \(c.allowsContentModifications)")
}

let now = Date()
let from = now.addingTimeInterval(-12 * 3600)
let to   = now.addingTimeInterval(24 * 3600)
let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
let events = store.events(matching: pred)

print("\n=== Etkinlikler (-12s / +24s penceresi): \(events.count) ===")
for e in events.prefix(10) where !e.isAllDay {
  let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
  print("\n  \(f.string(from: e.startDate)) – \(f.string(from: e.endDate))  \(e.title ?? "?")")
  print("    takvim : \(e.calendar.title)")
  if let u = e.url { print("    URL    : \(u.absoluteString.prefix(80))") }
  if let o = e.organizer { print("    düzenleyen: \(o.name ?? "?")") }
  if let att = e.attendees {
    let people = att.filter { $0.participantType == .person && $0.participantStatus != .declined }
    let rooms  = att.filter { $0.participantType == .room || $0.participantType == .resource }
    print("    katılımcı (\(people.count)): \(people.compactMap(\.name).joined(separator: ", "))")
    if !rooms.isEmpty { print("    oda/kaynak (elenecek): \(rooms.compactMap(\.name).joined(separator: ", "))") }
  }
}
