# ora — Marka Kimliği (native)

Renkler, ton ve kişilik önceki ora'dan **birebir devralındı** — bu bir yeniden
markalama değil, aynı ürünün yerel yeniden yazımıdır. Değişen tek şey
uygulama katmanı: Tailwind sınıfları yerine SwiftUI `Color` token'ları,
Lucide yerine SF Symbols.

## Marka Özü
- Ad: ora (Latince: söz, ağız)
- Slogan: "Sesi bilgiye dönüştürür"
- Aura: Güvenilir, minimalist, akıllı, odaklanmış, %100 yerel
- Vaat: Toplantılardaki karmaşayı netliğe kavuşturur

## Renk Paleti
| Rol | Ad | Hex | Token |
|---|---|---|---|
| Kağıt — ana tuval | Paper Cream | `#FAF6F0` | `.oraPaper` |
| Kağıt — kenar şerit | Chrome Cream | `#F3ECE1` | `.oraChrome` |
| Nötr vurgu / hover | Quiet Gray | `#F5F5F7` | `.oraGray` |
| Metin & tipografi | Slate Black | `#333333` | `.oraInk` |
| İkincil metin | — | `#888888` | `.oraInkMuted` |
| Vurgu | Core Blue | `#1A56A3` | `.oraBlue` |
| Seçili arka plan | — | `#EEF3FB` | `.oraBlueSoft` |
| Kayıt durumu | Active Red | `#E53935` | `.oraRed` |
| Kart / panel içi | Pure White | `#FFFFFF` | `.oraSurface` |
| Kenarlık | Soft Border | `#E8E8E8` | `.oraBorder` |

Bu tablo tek kaynaktır. Renkler `Color+Ora.swift` içinde **bir kez** tanımlanır;
görünümlerde ham hex veya `Color(red:green:blue:)` yazılmaz.

## Tipografi
Fontlar uygulama kaynağı olarak **paketlenir** (toplam ~232 KB), indirilmez.
Dosyalar önceki projede hazır: `../src/renderer/assets/fonts/` — masaüstü için
woff2 yerine ttf/otf sürümleri gerekir, `scripts/fetch-fonts` eşdeğeriyle üretilir.

- Gövde: **Inter** (Regular 400, Medium 500, Bold 700)
- Başlık / özet metni: **Source Serif 4**
- Transkript: sistem monospace (`.system(.body, design: .monospaced)`)
- `latin-ext` alt kümesi **zorunlu** — Türkçe ı İ ğ Ğ ş Ş bu alt kümededir

| Kullanım | Boyut | Ağırlık | Renk |
|---|---|---|---|
| Gövde metni | 14 | Regular | `.oraInk` |
| Bölüm başlığı | 13 | Medium, uppercase + letter-spacing | `.oraInk` |
| Küçük etiket | 12 | Regular | `.oraInkMuted` |

> Alternatif: SF Pro'ya geçilirse paketleme sıfırlanır ve uygulama daha
> "yerel" hisseder, ama marka kimliğinden sapılır. Karar verilmedi —
> varsayılan Inter'dir, değiştirmeden önce sor.

## Logo Kuralları
- Uygulama adı **her zaman** küçük harf: **ora**
- Asla: Ora, ORA, O.R.A.
- Başlık çubuğunda ve onboarding'de: "ora", Inter Medium, `.oraInk`,
  arka plan `.oraChrome`

## UI Kişiliği
- Bol boşluk, dekoratif öğe yok
- Gradyan **yok**
- Gölge en fazla: `.shadow(color: .black.opacity(0.08), radius: 3, y: 1)`
- Köşe yarıçapı en fazla 8
- İkonlar: SF Symbols — başka ikon seti yok
- Animasyon: yalnızca ince, en fazla `.easeOut(duration: 0.15)`
- Düz yazı içinde kalın başlık kullanma
- Yoğunluk: rahat, sıkışık değil — cömert padding

## Bileşen Renk Kuralları
- Birincil buton: `.oraBlue` zemin, beyaz metin
- İkincil buton: `.oraSurface` zemin, `.oraInk` metin, `.oraBorder` kenarlık
- Aktif / seçili: `.oraBlue` metin, `.oraBlueSoft` zemin
- Yıkıcı eylem: `.oraRed`
- Kayıt butonu **yalnızca**: `.oraRed`, aktifken nabız animasyonu
- Sol kenar çubuğu + başlık çubuğu: `.oraChrome`
- Ana panel + sohbet paneli: `.oraPaper`
- Toplantı sağlık kartları: `.oraSurface` zemin, ince `.oraBorder`

Pencere arka planı (`NSWindow.backgroundColor`) tuvalle **aynı** olmalı;
aksi halde şerit ile tuval aynı renkmiş gibi algılanır. Başlık çubuğunda
trafik ışığı boşluğu şeffaf bırakılmaz.

## Ne YAPILMAMALI
- Active Red'i (`#E53935`) kayıt bağlamı dışında kullanma
- Saf siyah (`#000000`) kullanma — her zaman Slate Black (`#333333`)
- Aynı ekranda ikiden fazla font ağırlığı kullanma
- Dekoratif illüstrasyon veya stok fotoğraf ekleme
- Gradyan kullanma
- Uygulama adını küçük harf "ora" dışında yazma
