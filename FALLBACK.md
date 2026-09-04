# ora (native) — Yedek Yollar

Bu dosya "Apple yığını yetmezse ne yaparız" sorusunun cevabıdır.
Her yedek yol, **mimarinin geri kalanını koruyacak** şekilde tasarlandı:
SwiftUI, GRDB, ScreenCaptureKit ve tek-süreç modeli hiçbir senaryoda değişmez.
Değişen yalnızca ilgili modülün içidir — ARCHITECTURE.md'deki protokoller
tam da bu yüzden var.

---

## 1. Transkripsiyon doğruluğu yetersizse → whisper.cpp

**Tetikleyici:** Faz 0 kıyaslamasında `DictationTranscriber`'ın WER'i
WhisperX medium'dan belirgin kötü çıkarsa (özellikle uzak alan mikrofon,
üst üste konuşma, teknik terim yoğun toplantılarda).

**Çözüm:** `Transcribing` protokolünün ikinci bir uygulaması olarak
whisper.cpp. Python/PyTorch **geri gelmez** — whisper.cpp saf C/C++'tır,
Metal ve Core ML hızlandırma ile M3'te doğrudan çalışır ve SPM ile
uygulamaya statik bağlanır.

- Paket: `whisper.cpp` (MIT) — SPM hedefi olarak eklenir veya
  `libwhisper.a` derlenip köprülenir
- Model: `ggml-large-v3-turbo-q5_0` (~550 MB) veya `medium-q5_0` (~500 MB) —
  ilk açılışta indirilir, uygulamaya paketlenmez
- Türkçe kalitesi WhisperX ile aynı (aynı model ağırlıkları)
- Maliyet: ~550 MB indirme + ~200 MB binary; hâlâ eski yığının ~1/4'ü

**Melez seçenek (önerilen):** İki motoru da tut, kullanıcıya bir ayar ver:
- **Hızlı** (varsayılan): `DictationTranscriber` — 45x gerçek zamanlı, indirme yok
- **Yüksek doğruluk**: whisper.cpp — yavaş ama en iyi kalite

Melez yol `Transcribing` protokolü sayesinde neredeyse bedava; Faz 0 sonucu
ne olursa olsun bu seçenek masada kalsın.

---

## 2. Foundation Models kullanılamıyorsa

**Tetikleyici:** Kullanıcı Apple Intelligence'ı açmıyor/açamıyor, veya
4096 token penceresi map-reduce'a rağmen kalite için yetersiz kalıyor.

**Önce:** Uygulama bu durumda **çökmez ve işlevsiz kalmaz.** Transkripsiyon,
arama, dışa aktarım, düzeltmeler — hepsi çalışır; yalnızca özet ve sohbet
devre dışı kalır. Bu, Faz 4'ün kabul kriteridir.

**Gerekirse:** `Intelligent` protokolünün ikinci uygulaması olarak
`llama.cpp` (Metal) + Qwen3 4B GGUF. Yine C/C++, yine Python yok.
Kazanç: 32k+ bağlam penceresi, map-reduce ihtiyacı azalır.
Maliyet: ~2.5 GB model indirmesi — yani eski ora'nın en ağır parçasının geri
dönmesi. Bu yüzden **son çare**, ilk hamle değil.

---

## 3. Konuşmacı ayrıştırma (diarization) gerekirse

Apple'ın konuşmacı ayrıştırma API'si **yok**. Bu, yeni mimarinin
WhisperX'e göre tek gerçek gerilemesidir.

**Hafifletici etken:** Stereo kanal ayrımı sayesinde "ben vs. karşı taraf"
ayrımı hiçbir model çalıştırmadan zaten çözülüyor. Tek konuşmacılı karşı
taraf (birebir görüşmeler) ve toplantı özetinin çoğu kullanımı bunu yeterli
buluyor. Kanal düzeyi ayrımla yetinmek geçerli bir üründür.

Sistem kanalı içinde kişi ayrımı gerçekten gerekirse, artan zorlukta:

1. **Kanal + zaman boşluğu sezgiseli** — bedava. Uzun sessizlikten sonra
   gelen konuşmayı yeni konuşmacı adayı say, kullanıcıya elle etiketletme
   arayüzü ver. Çoğu toplantı için sürpriz derecede iyi çalışır.
2. **Toplantı platformundan isim çekme** — Teams/Zoom aktif konuşmacıyı
   ekranda gösterir; erişilebilirlik API'si ile okumak mümkün olabilir.
   Araştırılmadı, doğrulanması gerekir.
3. **Core ML konuşmacı gömülemesi** — pyannote embedding modelini Core ML'e
   dönüştür, kayan pencerede gömüleme çıkar, kümele. Gerçek çözüm ama
   en pahalısı; ancak 1 ve 2 yetersiz kaldığında yapılmalı.

`sherpa-onnx` da bir seçenek ama onnxruntime'ı geri getirir (~80 MB) —
Core ML dönüşümü tercih edilir.

---

## 4. Bütün Apple yolu çökerse — çıkış planı

Böyle bir senaryoda dönülecek yer eski Electron ora **değildir**;
`../` altındaki proje ölçülmüş performans sorunları nedeniyle terk edildi
(bkz. RESEARCH.md §0). Doğru geri çekilme hattı:

SwiftUI + GRDB + ScreenCaptureKit **kalır**, `Transcribing` → whisper.cpp,
`Intelligent` → llama.cpp. Bu, hâlâ tek süreçli, Python'suz, Node'suz,
notarize edilebilir bir macOS uygulamasıdır — sadece ~3 GB model indirir.
Yani en kötü senaryoda bile eski mimarinin ağırlık sorunlarının çoğu geri
gelmez.

---

## 5. CoreAudio süreç tap'i çalışmazsa → ScreenCaptureKit

**Tetikleyici:** İmzalı/sandbox'lı uygulamada tap TCC onayı alınamıyor, veya
belirli bir toplantı uygulamasının sesi tap'e düşmüyor.

**Çözüm:** ScreenCaptureKit ile audio-only `SCStream`. Maliyeti, kullanıcıdan
**ekran kaydı izni** istemek — bu ürün için gözle görülür bir güven bedelidir
(uygulamanın ekranı gördüğünü ima eder, oysa görmez). Bu yüzden yedek yoldur,
ilk tercih değil. `AudioCapturing` protokolünün ikinci uygulaması olarak yazılır.

## 6. Canlı transkripsiyon beklenenden pahalı çıkarsa

**Tetikleyici:** Gerçek toplantı sesinde (TTS değil) CPU maliyeti ölçülenin
belirgin üstüne çıkarsa, veya iki kanal eşzamanlı koşarken kayıt hattı etkilenirse.

**Çözüm:** Canlı transkripsiyon **kapatılabilir bir ayardır**, mimari değil.
Kapatıldığında ürün eski davranışa döner: kayıt sırasında yalnızca ses yazılır,
transkripsiyon kayıt sonrası tam geçişte yapılır. Bu yüzden Faz 3'te canlı mod
ile tam geçiş **ayrı kod yolları** olarak tutulur ve tam geçiş her zaman tek
başına çalışabilir durumda kalır.
