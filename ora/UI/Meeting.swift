import Foundation

/// Arayüzün Faz 1'de ihtiyaç duyduğu en küçük toplantı temsili.
/// Gerçek kalıcı model ve GRDB kayıtları Faz 5'te (`meetings` tablosu) gelir.
struct Meeting: Identifiable, Hashable {
    let id: Int64
    let title: String
    let date: Date
    let duration: TimeInterval
}
