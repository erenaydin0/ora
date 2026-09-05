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

## Faz 1 — İskelet ✅
- [x] Xcode projesi, SwiftUI App, macOS 26 hedefi, Apple Silicon
- [x] Info.plist izin metinleri (Türkçe), entitlements, sandbox
- [x] SPM: GRDB.swift (7.11.1 çözüldü, henüz kullanılmıyor — Faz 5)
- [x] `AppPaths` — Application Support altında recordings/ logs/ ora.sqlite
- [x] `Log` — OSLog + `{base}/logs/ora.log` dosya köprüsü
- [x] BRAND.md renklerini asset kataloğunda tanımla; token'lar derleme zamanında
      üretilir (`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS`),
      `Color+Ora.swift` palet belgesi + `OraStyle` (gölge/köşe/geçiş) tutar
- [x] Boş 3 sütunlu pencere ayakta (`NavigationSplitView` + `.inspector`)

*Çıktı:* açılan, hiçbir şey yapmayan ama doğru görünen uygulama

**Faz 1'de kapatılmayan, bilinçli bırakılanlar:**
- **Uygulama ikonu yok** — Faz 7
- **Karanlık mod paleti yok.** BRAND.md tek bir açık palet tanımlıyor, bu yüzden
  uygulama `NSAppearance(named: .aqua)` ile açık moda sabitlendi. Karanlık mod
  istenirse önce BRAND.md'ye ikinci bir palet yazılmalı

---

## Faz 2 — Ses Yakalama ✅ (en riskli teknik parça, erken yapıldı)
- [x] `AVAudioEngine` ile mikrofon yakalama
- [x] **CoreAudio süreç tap'i** ile sistem sesi (`CATapDescription` +
      `AudioHardwareCreateProcessTap` + özel toplama cihazı + IOProc).
      ScreenCaptureKit kullanılmadı
- [x] `bundleIDs` ile toplantı uygulamasını hedefle, bulunamazsa kendimiz hariç
      global tap'e düş. **Tarayıcılar hedef listesinde değil** — sesleri yardımcı
      süreçten çıkıyor (RESEARCH.md §13.3). Ayrıca kapsamlı tap sessiz kalırsa
      global'e geçen bir gözcü var
- [x] **İmzalı app bundle'da TCC istemi doğrulandı** — çıkan istem mikrofon istemi;
      ekran kaydı istemi çıkmadı, ayrı bir sistem sesi istemi de çıkmadı
- [x] İki akışı **ortak zaman tabanına** hizala — host time damgası; ölçülen
      kanal hizalaması 20 ms (RESEARCH.md §13.5)
- [x] **Artımlı stereo WAV yazımı**: 16 kHz · 16 bit · ch0 = mic, ch1 = sistem;
      1 sn'de bir flush. Bellekte yalnızca son ~1 sn durur (kural #12)
- [x] Kısa kalan kanal sessizlikle doldurulur, kırpılmaz (kural #11) — örnekler
      mutlak frame konumuna yazıldığı için bu yapısal olarak sağlanıyor
- [x] Sistem sesi alınamazsa yalnız-mikrofon moduna düş, kayıt kesilmez
- [x] Çökme kurtarma: `.recording` işaretçisi + başlık onarımı; `kill -9` ile test edildi
- [x] `liveBuffers` akışı — `bufferingNewest(16)`, tüketici geri kalırsa buffer düşer

*Çıktı:* Kayıt başlat/durdur, diskte geçerli stereo WAV. **Ölçümler: RESEARCH.md §13.**

**Faz 2'de bilinçli bırakılanlar:**
- Kanal seviye göstergesi (VU) yok — menü bar yüzeyiyle birlikte Faz 6'da
- Menü bar öğesi ve çentik HUD yok — Faz 6/7
- Toplantı id'si geçici olarak zaman damgası; `meetings` satırı Faz 5'te gelince
  gerçek id kullanılacak
- Electron uygulamalarının (Teams/Slack) sesinin ana bundle'dan mı yardımcı
  süreçten mi çıktığı **ölçülmedi**; gözcü her iki durumda da doğru davranıyor,
  ama gerçek bir Teams toplantısında teyit edilmeli

---

## Faz 3 — Transkripsiyon ✅ (canlı + kayıt sonrası)
- [x] `SpeechAnalyzer` + `DictationTranscriber(tr-TR)` sarmalayıcı
- [x] Kanal ayırma: stereo WAV'dan ch0 ve ch1 ayrı mono akış olarak beslenir
- [x] mic kanalı → speaker "Ben"; sistem kanalı → "Katılımcı"
- [x] Kelime düzeyi zaman damgası + güven skoru `AttributedString` run'larından
- [x] Segmentler ortak zaman eksenine göre sıralanır (`transcripts` tablosu Faz 5'te;
      şimdilik bellekte)
- [x] `AssetInventory` ile locale kurulu değilse indir + ilerleme göster + `reserve`
- [x] Sessiz kanalı atla (tepe genlik < 0.005)
- [x] Dil seçimi: Türkçe / İngilizce / **Otomatik**. Apple'da konuşulan dili tanıyan
      API yok; otomatik seçim ilk ~40 sn'yi kurulu adaylarla çözüp ortalama güven
      skorunu karşılaştırır
- [x] **Canlı mod**: `liveBuffers` tüketilir, `.volatileResults` ile akan metin;
      kesinleşmemiş metin `.oraInkMuted`, kesinleşen `.oraInk`
- [x] Canlı transkript hata verirse sessizce durur, kullanıcıya not düşer,
      **kayıt etkilenmez** — gerçek bir hatada doğrulandı (RESEARCH.md §14.1)
- [x] Canlı çıktı ile tam geçiş çeliştiğinde **tam geçiş kazanır** (canlı segmentler
      tam geçiş bitince silinir)

*Çıktı:* Kayıt sırasında akan canlı transkript + kayıt sonrası nihai transkript.
**Ölçümler: RESEARCH.md §14.**

**Faz 3'te bilinçli bırakılanlar:**
- Segmentler DB'ye **yazılmıyor** — `transcripts` tablosu Faz 5'te gelince bağlanacak
- Vocabulary (`ContentHint.customizedLanguage`) parametre olarak geçiyor ama
  kullanılmıyor — Faz 6
- Canlı modun uygulama içi doğrulaması yapılmadı (her derlemede TCC istemi çıkıyor);
  damga düzeltmesi bilerek bozulmuş damgalarla probe üzerinde doğrulandı

---

## Faz 4 — Foundation Models ✅
- [x] `availability` kapısı; kullanılamama nedeni Türkçe olarak Özet sekmesinde
      yazılır ve Ayarlar'a yönlendirir
- [x] **Noktalama restorasyonu** adımı. Model kelime değiştirirse o satır
      **reddedilir** ve orijinal korunur; guardrail'e takılırsa yalın istemle
      bir kez daha denenir
- [x] Map-reduce özetleyici: ~10.000 karakterlik parçalar, parça başına yeni oturum,
      kısmi özetler uzun kalırsa ek indirgeme turu
- [x] `@Generable` şemalar: `Ozet` (genelBakis[], kararlar[],
      aksiyonlar[kisi/gorev/baglam/sonTarih]), `ParcaOzeti` (konular[] + aksiyonlar[]),
      `ToplantiOzeti` (birleştirme çıktısı)
- [x] Konu blokları — başlık **ve maddeler** `@Generable KonuBlogu` ile, zaman aralığı
      parçanın segmentlerinden (LLM'e sorulmaz)
- [~] Sağlık metrikleri **kaldırıldı** (DESIGN.md §4). Eskiden: konuşma payı, ölü hava —
      üst üste binen aralıklar bir kez sayılır
- [x] Model kullanılamıyorsa transkript yine gösterilir, yalnız özet devre dışı

*Çıktı:* Türkçe özet + aksiyon maddeleri (son tarihli). **Ölçümler: RESEARCH.md §15.**

**Faz 4'te bilinçli bırakılanlar:**
- Ayrı bir onboarding **ekranı** yazılmadı; Apple Intelligence kapalıysa neden ve
  ne yapılacağı Özet sekmesinde Türkçe bir not olarak çıkıyor. Tam onboarding akışı
  Faz 7'de (ilk açılış) yapılacak
- Özet DB'ye yazılmıyor (`summaries`, `action_items`, `topic_segments` tabloları Faz 5)
- Toplantı sohbeti (`answer`) protokole eklenmedi — Faz 6

---

## Faz 5 — Depolama, Arama, UI ✅
- [x] GRDB şeması + migration'lar (CLAUDE.md'deki şema, üç migration:
      şema → FTS → indeksler)
- [x] FTS5 sanal tablosu + insert/delete/update trigger'ları
- [x] Sol kenar çubuğu: toplantı listesi, başlık + FTS5 transkript araması,
      yeniden adlandırma, onaylı silme
- [x] Orta panel: **Özet | Transkript** (Konuşmacılar sekmesi yok — DESIGN.md §4;
      istatistikler Özet içindeki kompakt kartta)
- [x] Transkriptte çift tıklayarak düzeltme → `corrections` tablosu
- [x] Toplantı silme: cascade + FTS temizliği + ses dosyası
- [x] Dışa aktarım: Markdown + PDF (`ImageRenderer`), e-posta taslağı panoya

*Çıktı:* Kullanılabilir uygulama. **Ölçümler: RESEARCH.md §16.**

**Faz 5'te bilinçli bırakılanlar:**
- Toplantı listesi `ValueObservation` ile değil, elle `refresh()` ile tazeleniyor.
  Tek pencereli, tek yazarlı bir uygulamada yeterli; çok pencere gelirse değişir
- Arama sonuçlarında eşleşme parçacığı (`snippet`) sorgusu yazıldı ama arayüzde
  gösterilmiyor — liste satırına sığdırmak ayrı bir tasarım kararı
- `meeting_participants` ve `participants` tabloları şemada var, henüz yazan yok
  (takvim entegrasyonu Faz 6)
- Arayüzde doğrulanmayan yollar: arama kutusuna yazma, bağlam menüsünden silme
  ve dışa aktarım panelleri. Depolama tarafı SQL düzeyinde doğrulandı (§16)

---

## Faz 6 — Akıllı Katman ✅
- [x] Vocabulary: `ContentHint.customizedLanguage` + `SFSpeechLanguageModel.Configuration`;
      `corrections` tablosundan beslenir, `pending` → kullanıcı onayı.
      **Ölçüldü:** `weight 1.0` + `count 30` ile terim tutma 2/5 → 4/5 (RESEARCH.md §17.1)
- [x] Toplantı sohbeti (transkript üzerinde soru-cevap, map-reduce ile;
      ilgisiz parçalar "YOK" ile elenir, `chat_history` tablosuna yazılır)
- [x] Düşük güç / termal ertelemesi: `isLowPowerModeEnabled` + `thermalState`;
      ertelenirse Özet sekmesinde "Şimdi özetle" düğmesi çıkar
- [x] **Toplantı algılama** — CoreAudio olay dinleyicileri (`isRunningInput`),
      `ps aux` polling yok. Dışlama listesi, 10 sn titreşim engelleyici,
      uygulama başına 30 dk soğuma, süreç listesi değişince yeniden bağlanma
- [x] Otomatik durdurma: mikrofon 30 sn bırakıldıysa arayüzde şeritle önerilir
- [x] Uygulama başına "her zaman kaydet" tercihi (Ayarlar'dan da yönetilir)
- [x] **Otomatik başlık transkriptten** Foundation Models ile üretilir
      (pencere başlığı okunmaz)
### Takvim entegrasyonu (EventKit) ✅
- [x] Ayarlarda opt-in anahtarı + **hangi takvimler** çoklu seçimi
      (varsayılan: kapalı, hiçbir takvim seçili değil)
- [x] `requestFullAccessToEvents` + Türkçe izin metni ("yazmaz, veri çıkmaz")
- [x] Mikrofon sinyali ile ±10 dk toleransla eşleştirme
- [x] Katılımcı filtresi: `participantType == .person` **ve** `status != .declined`
- [x] `meeting_participants` join tablosu + `meetings.calendar_event_id`
- [x] **Katılımcı adları sözlüğe besleniyor** (`source = 'calendar'`, doğrudan `active`)
- [x] Başlık önceliği: takvim adı → LLM'in ürettiği başlık → tarih/saat
- [x] `event.URL` / `notes`'tan toplantı uygulaması çıkarılıp Capture'a veriliyor
      (saklanmaz); tarayıcı linkleri global tap'e düşer
- [x] `EKEventStoreChangedNotification` dinleyicisi (polling yok)
- [x] Yaklaşan toplantı verisi hazır (`upcomingEvent`) — menü bar popover'ı Faz 7
- [ ] Etkinlik bazlı otomatik kayıt — **Faz 7'ye bırakıldı**; uygulama başına
      "her zaman kaydet" bugünkü ihtiyacı karşılıyor
- [ ] **Konuşmacı ayrıştırma (diarization)** — ROADMAP'te zaten *isteğe bağlı*
      işaretliydi. Apple API'si yok; kanal düzeyi ayrım senaryoların çoğunu
      karşılıyor. Yapılmadı, FALLBACK.md §3 açık duruyor

**Faz 6'da bilinçli bırakılanlar / doğrulanmayanlar:**
- **Gerçek bir toplantıyla uçtan uca algılama denenmedi.** CoreAudio dinleyici
  mekanizması RESEARCH.md §9'da, uygulamada da açılışta doğrulandı
  ("27 süreç izleniyor"), ama Teams/Zoom toplantısıyla öneri→kayıt akışı
  koşturulmadı
- Bildirim izni bu makinede verilmedi; eylemli bildirimin butonları
  arayüzdeki şeritle aynı işi yapıyor ama bildirim yüzeyi sınanmadı
- Menü bar öğesi ve çentik HUD — Faz 7 (DESIGN.md §2-3)

## Faz 7 — Paketleme ✅
- [x] Uygulama ikonu — BRAND paletiyle çizilir (`scripts/make-icon.swift`):
      konuşan ağız (Carmine zemin, Deep dudak, krem açıklık ve söz). Gradyan yok
- [x] Menü bar öğesi (`MenuBarExtra`) — **taşıyıcı yüzey**. Popover'da geçen süre,
      iki kanalın seviye göstergesi, canlı transkriptin son satırı, Durdur,
      sıradaki toplantı, "Pencereyi aç"
- [x] Kayıt sırasında `.oraRed` nokta (nabız `.accessibilityReduceMotion`'a saygılı)
- [x] Son pencere kapanınca uygulama kapanmaz — menü bar taşıyıcı olduğu için
      kayıt ve algılama sürer
- [x] İlk açılış onboarding: mikrofon izni, sistem sesi açıklaması,
      Apple Intelligence durumu, dil seçimi
- [x] `.dmg` üretimi — `scripts/build-release.sh`. **Ölçüldü:** 7,7 MB uygulama,
      3,7 MB .dmg (RESEARCH.md §18)
- [x] `ORA_SIGN_IDENTITY` derleme ayarı — kendinden imzalı sertifikayla sabit
      kimlik, TCC izinlerinin her derlemede sıfırlanmasını bitirir (README)
- [ ] **Code signing + notarization çalıştırılamadı** — bu makinede kod imzalama
      kimliği yok. Betik kimlik ve `ora-notary` profili varsa kendiliğinden
      imzalar ve notarize eder; ek kod gerekmiyor, Apple Developer üyeliği gerekiyor
- [ ] **Otomatik güncelleme (Sparkle) — kullanıcı kararıyla eklenmedi.**
      GRDB dışında ikinci bir bağımlılık olurdu ve notarize edilmiş bir dağıtım
      kanalı olmadan güncelleme sunucusu zaten kurulamaz. Dağıtım başlayınca
      yeniden değerlendirilir

> Eski ora'nın Faz 9'da tıkandığı yer gömülü Python'du. Yeni mimaride gömülecek
> çalışma zamanı olmadığı için bu faz standart bir Xcode arşivi oldu ve ilk
> denemede `.dmg` üretti.

**Faz 7'de bilinçli bırakılanlar:**
- **Çentik HUD** (DESIGN.md §3) yazılmadı. DESIGN onu "ek katman, taşıyıcı değil"
  diye tanımlıyor ve taşıyıcı yüzey olan menü bar hazır. Geometri RESEARCH.md
  §10'da ölçülü duruyor; istenirse eklenir
- Global kısayol (⌘⇧R) bağlanmadı
- Menü bar popover'ı ve onboarding arayüzde görüldü; **kayıt sırasındaki**
  menü bar davranışı (kırmızı nokta, seviye çubukları, akan satır) gerçek bir
  kayıtla sınanmadı

## Faz 8 — Elimizdekini Kullan ✅
> Kaynağı **COMPETITION.md**: rakip incelemesinde ora'da hiç olmayan ama
> zaten elimizdeki veriyle yapılabilen işler. Bu fazda yeni bağımlılık,
> yeni izin ve yeni şema **yok**.

- [x] **Ses oynatıcı + transkript senkronu** (§4.1) — `AudioPlayback`:
      akış hâlinde okuma (0,5 sn'lik parçalar, dosya asla tümüyle bellekte
      değil), kanal seçici (Karışım / Ben / Katılımcı), perde koruyan hız
      (1× / 1,5× / 2×), satır saatine tıklayınca oradan çalma, çalınan satırın
      vurgulanması ve takip edilmesi. Ölçüm: RESEARCH.md §25.1
- [x] **Aksiyon panosu** (§4.2) — kenar çubuğunda toplantılardan bağımsız kök;
      Bana düşenler / Başkalarında / Kime düştüğü belirsiz; kaynak toplantıya
      gidiş; tamamlananlar anahtarı
- [x] **Alıntı bağı** (§4.3) — aksiyon, karar, genel bakış ve konu maddeleri
      transkriptteki yerine götürür ve oynatıcıyı o ana kurar. IDF ağırlıklı
      eşleştirme; eşleşme oranı %57 → %86 (RESEARCH.md §25.2)
- [x] **Arama parçacığı ve ⌘F** (§4.4) — kenar çubuğu sonucunda eşleşen yer
      görünür; transkript içinde eşleşme sayacı ve gezinme
- [x] **Depolama yönetimi** (§4.5) — boyut, AAC sıkıştırma (11,5×, kanal
      ayrımı korunuyor — RESEARCH.md §25.3), saklama süresi, "yalnızca sesi sil"
- [x] **Küçük işler** (§4.16) — gerçek global kısayol (⌘⇧R, Carbon
      `RegisterEventHotKey`, izin istemez), transkript satırı silme,
      konuşmacı etiketini düzeltme, kayıt bildirimi hatırlatıcısı

**Faz 8'de bilinçli bırakılanlar:**
- Aksiyon panosundan doğrudan transkriptteki ana atlama yok; pano toplantıyı
  açar, alıntı bağı oradan çalışır
- Alıntı bağı **kalıcı değil**, her açılışta hesaplanır. Şema değişmedi;
  eşleştirme ucuz (transkript başına bir dizin)
- Oynatıcı canlı modda yok — kayıt sürerken çalınacak bir dosya yok

## Faz 9 — Not Defteri (sıradaki, COMPETITION.md §7)
- [ ] Kullanıcının kendi notu + kayıt sonrası zenginleştirme (§4.6)
- [ ] Kayıt sırasında "önemli an" işareti (§4.9)
- [ ] Toplantı şablonları (§4.7)
- [ ] Kanal başına dil — mikrofon tr, sistem en (§4.8)

## Kapsam Dışı — bilerek yapılmayacaklar
- Windows / Linux desteği
- Bulut senkronizasyonu, hesap sistemi, telemetri
- Kayıt sırasında LLM çalıştırmak (kural #1). Canlı transkripsiyon
  kapsam **içindedir** — bkz. RESEARCH.md §6
- Video kaydı — yalnızca ses
