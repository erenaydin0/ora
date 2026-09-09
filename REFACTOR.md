# ora (native) — `RecordingController` refactor'ı: kalıcı sonuçlar

> **Plan tamamlandı** (2026-09-09, altı adım). Bu dosya artık bir plan değil,
> planın kurduğu ve **bozulmaması gereken** değişmezlerin kaydıdır. Koddan ve
> CLAUDE.md'den buraya yapılan atıflar bu bölümlere gelir.

## Ölçüm (başlangıç durumu)

`RecordingController` 1114 satır, **11 bağımlılık**, ~80 dışa açık üye, 8 arayüz
dosyasından ~157 çağrı. Sorun boyut değildi — `FoundationIntelligence` de 870
satır ve orası sorun değil — **bağımlılık ve sorumluluk sayısıydı**.

Sonuç: 1114 → 658 satır, 0 → 46 test (bugün 100), hattın ürettiği içeriği süzen
kapı **15 → 1**.

## §2 — Hattın arayüze yazması tek kapıdan geçer

`MeetingPipeline` görünüm durumu tanımaz. Ürettiği her şeyi `meetingID` taşıyan
`PipelineEvent` olarak yayar; "kullanıcı hâlâ bu toplantıya mı bakıyor" sorusu
**tek yerde** sorulur (`MeetingLibrary.display(_:)`).

**Bozmayın:** hattın ürettiği yeni bir alan eklerken controller'a property
değil, `PipelineEvent.Kind`'a vaka eklenir. Eskiden 15 ayrı `onScreen` çağrısı
vardı ve unutulan her biri sessiz bir toplantılar-arası sızıntıydı.

## Adım 3-6 — sorumluluğun sahipleri

- `RecordingSession` — kayıt sürerken (ses yazımı + canlı transkripsiyon).
  **Kural #2** (canlı transkripsiyon kaydın önüne geçmez) burada testle korunur.
- `MeetingLibrary` — liste, arama, seçim ve "ekranda ne var". İki yarış
  (geç gelen yükleme, hattın ürettiği içerik) orada tek yerde kapanır.
- `MeetingSuggestions` — algılama → öneri → karar. Teslim
  `withObservationTracking` ile; polling yok.
- `CalendarReader.match(at:app:)` — takvim eşleştirme **politikası**.
  Controller yalnızca sonucu taşır.

## `Pipeline`'ı `actor` yapmak — yapılmamalı, ertelenmiş değil

Ölçüldü (2026-09-09): hattın çağırdığı ağır işin tamamı zaten ana iş
parçacığından çıkıyor — `Transcribing.transcribe`, `Intelligent`'ın ağır
adımları ve `AudioArchive.compress` **`@concurrent`** işaretli (RESEARCH.md
§30.2), `MeetingStore`'un gövdeleri GRDB'nin kuyruğunda. Ana iş parçacığında
kalan iş birkaç `await`, bir `Set` ekleme ve dinleyici çağrısı.

Bedeli ise üç yapısal geri adım:

1. `isRunning` yalnızca `await` ile okunur hâle gelir; oysa `isTranscribing` /
   `canCorrect` / `canSummarize` / `canRetry` SwiftUI `body` **içinde** senkron
   okunuyor. Durumu MainActor'da aynalamak gerekirdi — yani bu refactor'ın
   kaldırdığı "aynı bilgi iki yerde" problemi geri gelirdi.
2. Olayların **senkron** teslimi bozulur. Bugünkü garanti: `await pipeline.…`
   döndüğünde ekran zaten güncel. `AsyncStream` bir tur gecikme koyar ve
   "işlem bitti ama ekran eski" penceresi yeniden açılır.
3. `settings` okumaları hop'a döner.

Kazanç ~sıfır.

## Bilinçli olarak yapılmayanlar

- **Arayüze bakan ~80 üye.** 8 arayüz dosyasına dokunmamak için geçirgen
  bırakıldı; yüzeyi daraltmak arayüzü de değiştirmek demek.
- **Kullanıcının elle değiştirdiği başlık.** "Şimdi özetle" hâlâ üretilmiş
  başlığı yazabilir; "yeniden adlandırıldı" işareti yok. Ayrı iş.
