# ora (native) — Yol Haritası

Her faz **çalışan ve commit edilebilir** bir durumla biter. Faz atlanmaz.
Kapsam dışı işler sonraki faza yazılır, o an yapılmaz.

---

## Faz 0 — Doğruluk Kapısı (önce bu, kod yazmadan önce)
> Bu fazın amacı yazmak değil, **karar vermek**. RESEARCH.md'deki doğruluk
> testi TTS sesiyle yapıldı; gerçek toplantı sesi çok daha zordur.

Eski ora ile kıyaslama **yapılmayacak** — doğruluk, kendi yazdığımız uygulamayla
gerçek kullanımda değerlendirilecek. Bu fazın işi kıyaslama değil, gerçek
(TTS olmayan) sesin `DictationTranscriber`'ı nerede zorladığını görmek.

- [ ] `probes/transcribe.swift`'i **gerçek konuşma** üzerinde koştur:
      kendi sesinle 5-10 dakikalık Türkçe konuşma kaydet (QuickTime yeterli),
      mümkünse bir tanesi hoparlörden çalan ikinci bir sesle birlikte olsun
- [ ] Şunları not et: teknik terimlerde, özel isimlerde ve hızlı konuşmada
      hata oranı; uzak alan (`.farField`) ipucunun etkisi; noktalamanın gerçekten
      hiç gelmediğinin teyidi
- [ ] `contentHints: [.customizedLanguage(...)]` ile özel sözlüğün ölçülebilir
      fayda sağladığını doğrula (birkaç şirket/ürün adı ver, öncesi-sonrası bak)

**Karar kuralı:**
- Sonuç günlük kullanım için yeterliyse → tam Apple yığını, Faz 1'e geç
- Belirgin şekilde yetersizse → FALLBACK.md'deki whisper.cpp yolu değerlendirilir
  (mimarinin geri kalanı değişmez). Bu dosyaya **şimdi dokunulmaz**; ancak
  gerçekten başarısız olursak açılır

*Çıktı:* `RESEARCH.md`'ye "Faz 0 sonucu" bölümü + karar. *Efor:* yarım gün

---

## Faz 1 — İskelet
- [ ] Xcode projesi, SwiftUI App, macOS 26 hedefi, Apple Silicon
- [ ] Info.plist izin metinleri (Türkçe), entitlements, sandbox
- [ ] SPM: GRDB.swift
- [ ] `AppPaths` — Application Support altında recordings/ logs/ ora.sqlite
- [ ] `Log` — OSLog + `{base}/logs/ora.log` dosya köprüsü
- [ ] BRAND.md renklerini `Color+Ora.swift` içinde asset katalog + token olarak tanımla
- [ ] Boş 3 sütunlu pencere ayakta

*Çıktı:* açılan, hiçbir şey yapmayan ama doğru görünen uygulama

---

## Faz 2 — Ses Yakalama (en riskli teknik parça, erken yap)
- [ ] `AVAudioEngine` ile mikrofon yakalama
- [ ] **CoreAudio süreç tap'i** ile sistem sesi (`CATapDescription` +
      `AudioHardwareCreateProcessTap` + toplama cihazı). ScreenCaptureKit kullanma
- [ ] `bundleIDs` ile toplantı uygulamasını hedefle (Teams/Zoom/Slack),
      bulunamazsa kendimiz hariç global tap'e düş
- [ ] **İmzalı app bundle'da TCC istemini doğrula** — `NSAudioCaptureUsageDescription`.
      Probe sandbox'sız komut satırında izin istemeden çalıştı; gerçek uygulamada
      istem çıkması beklenir, çıkan istemin ekran kaydı DEĞİL ses yakalama olduğunu teyit et
- [ ] İki akışı **ortak zaman tabanına** hizala — her iki kaynağın örneklerini
      `CMTime`/host time damgasıyla eşle. Eski ora'nın çözemediği sorun buydu;
      buffer sayısına göre hizalama yapma
- [ ] **Artımlı stereo WAV yazımı**: ch0 = mic, ch1 = sistem; 1 sn'de bir flush,
      append. Ses asla tamamı RAM'de tutulmaz (kural #12)
- [ ] Kısa kalan kanal sessizlikle doldurulur, kırpılmaz (kural #11)
- [ ] Sistem sesi izni reddedilirse yalnız-mikrofon moduna düş
- [ ] Çökme kurtarma: yarım kalan WAV açılışta bulunur, kullanıcıya sorulur
- [ ] `liveBuffers` akışı — canlı transkripsiyon için ikincil tüketici;
      tüketici geri kalırsa buffer düşürülür, diske yazım asla beklemez

*Çıktı:* Kayıt başlat/durdur, diskte geçerli stereo WAV. *Efor:* 3-4 gün

---

## Faz 3 — Transkripsiyon (canlı + kayıt sonrası)
- [ ] `SpeechAnalyzer` + `DictationTranscriber(tr-TR)` sarmalayıcı
- [ ] Kanal ayırma: stereo WAV'dan ch0 ve ch1'i ayrı `AVAudioFile` olarak besle
- [ ] mic kanalı → speaker "Ben"; sistem kanalı → "Katılımcı"
- [ ] Kelime düzeyi zaman damgası + güven skorunu `AttributedString` run'larından çıkar
- [ ] Segmentleri ortak zaman eksenine göre sırala, `transcripts`'e yaz
- [ ] `AssetInventory` ile locale kurulu değilse indir + ilerleme göster
- [ ] Sessiz kanalı atla
- [ ] Dil algılama: Türkçe/İngilizce seçimi (ayar + otomatik)
- [ ] **Canlı mod**: `liveBuffers`'ı tüket, `.volatileResults` ile akan metin göster.
      En iyi çaba — hata/gecikme kaydı etkilemez, kullanıcıya durum bildirilir
- [ ] Canlı çıktı ile kayıt sonrası tam geçiş çeliştiğinde **tam geçiş kazanır**

*Çıktı:* Kayıt sırasında akan canlı transkript + kayıt sonrası nihai transkript.
*Efor:* 3-4 gün

---

## Faz 4 — Foundation Models
- [ ] `availability` kapısı + Türkçe onboarding ekranı (Apple Intelligence kapalıysa)
- [ ] **Noktalama restorasyonu** adımı (Türkçe çıktı noktalamasız geliyor)
- [ ] Map-reduce özetleyici: ~10.000 karakterlik parçalar, parça başına yeni oturum
- [ ] `@Generable` şemalar: `Ozet` (genelBakis, kararlar, aksiyonlar[kisi/gorev/sonTarih])
- [ ] Konu segmentleri (`topic_segments`)
- [ ] Sağlık metrikleri: konuşma payı, ölü hava yüzdesi — bunlar **hesaplanır**,
      LLM'e sorulmaz (zaman damgaları elimizde)
- [ ] Model kullanılamıyorsa transkript yine gösterilir, yalnız özet devre dışı

*Çıktı:* Türkçe özet + aksiyon maddeleri (son tarihli). *Efor:* 3 gün

---

## Faz 5 — Depolama, Arama, UI
- [ ] GRDB şeması + migration'lar (CLAUDE.md'deki şema)
- [ ] FTS5 sanal tablosu + trigger'lar
- [ ] Eski ora SQLite'ından **içe aktarma** (şema bilerek uyumlu tutuldu)
- [ ] Sol kenar çubuğu: toplantı listesi, arama
- [ ] Orta panel: Özet | Transkript | Konuşmacılar sekmeleri
- [ ] Transkriptte tıklayarak düzeltme → `corrections` tablosu
- [ ] Toplantı silme (ses dosyası + FTS temizliği dahil)
- [ ] Dışa aktarım: Markdown + PDF (`ImageRenderer`), e-posta taslağı panoya

*Çıktı:* Kullanılabilir uygulama. *Efor:* 5-6 gün

---

## Faz 6 — Akıllı Katman
- [ ] Vocabulary: `ContentHint.customizedLanguage` + `SFSpeechLanguageModel.Configuration`
      ile özel sözlük; `corrections` tablosundan beslenir, `pending` → kullanıcı onayı
- [ ] Toplantı sohbeti (transkript üzerinde soru-cevap, map-reduce ile)
- [ ] Düşük güç / termal ertelemesi: `isLowPowerModeEnabled` + `thermalState`
      kontrolü ve kullanıcıya sorma (iki satır — ayrı alt sistem yok)
- [ ] **Toplantı algılama** — CoreAudio olay dinleyicileri (`isRunningInput`),
      `ps aux` polling yok. Dışlama listesi, 10 sn titreşim engelleyici,
      uygulama başına 30 dk soğuma. Detay: CLAUDE.md "Toplantı Algılama Kuralları"
- [ ] Otomatik durdurma: mikrofon 30 sn bırakıldıysa bitirmeyi öner
- [ ] Uygulama başına "her zaman kaydet" tercihi
- [ ] **Otomatik başlık transkriptten** Foundation Models ile üretilir
      (pencere başlığı okuma yok — ekran kaydı izni ister)
### Takvim entegrasyonu (EventKit) — Faz 6'nın en yüksek kazançlı parçası
- [ ] Ayarlarda opt-in anahtarı + **hangi takvimler** çoklu seçimi
      (varsayılan: kapalı, hiçbir takvim seçili değil)
- [ ] `requestFullAccessToEvents` + Türkçe izin metni ("yazmaz, veri çıkmaz")
- [ ] `event(overlapping:)` — mikrofon sinyali ile ±10 dk toleransla eşleştir
- [ ] Katılımcı filtresi: `participantType == .person` **ve**
      `status != .declined` (oda/kaynak elenir)
- [ ] `meeting_participants` join tablosu + `participants.email` (dedupe için,
      arayüzde gösterilmez) + `meetings.calendar_event_id`
- [ ] **Katılımcı adlarını `ContentHint.customizedLanguage`'a besle** — özel
      isim tanıma doğruluğunu doğrudan artırır. Faz 0'daki sözlük testiyle
      aynı mekanizma
- [ ] Başlık önceliği: takvim adı → LLM'in ürettiği başlık → tarih/saat
- [ ] `event.URL` / `notes`'tan toplantı uygulamasını çıkar → Capture'a hangi
      bundle'ın tap'leneceğini söyle (saklanmaz)
- [ ] `EKEventStoreChangedNotification` dinleyicisi (polling yok)
- [ ] Yaklaşan toplantı göstergesi (menü bar popover'ında "14:00 Sprint Planlama")
- [ ] Etkinlik bazlı otomatik kayıt — **opt-in**, etkinlik veya takvim başına
- [ ] **Konuşmacı ayrıştırma (diarization)** — sistem kanalı içinde kişi ayrımı.
      Apple API'si yok; seçenekler FALLBACK.md §3'te. Bu madde isteğe bağlıdır;
      kanal düzeyi ayrım çoğu senaryoyu zaten karşılıyor

*Efor:* 7-9 gün (takvim dahil)

---

## Faz 7 — Paketleme
- [ ] Uygulama ikonu, menü bar öğesi, kayıt sırasında kırmızı nokta
- [ ] Code signing + notarization + .dmg
- [ ] İlk açılış onboarding: izinler, Apple Intelligence kontrolü, dil seçimi
- [ ] Otomatik güncelleme (Sparkle — tek ek bağımlılık, onay gerektirir)

> Eski ora'nın Faz 9'da tıkandığı yer buydu (gömülü Python). Yeni mimaride
> gömülecek çalışma zamanı olmadığı için bu faz standart Xcode arşividir.

*Efor:* 2-3 gün

---

## Kapsam Dışı — bilerek yapılmayacaklar
- Windows / Linux desteği
- Bulut senkronizasyonu, hesap sistemi, telemetri
- Gerçek zamanlı canlı transkripsiyon (kural #1'i ihlal eder)
- Video kaydı — yalnızca ses
