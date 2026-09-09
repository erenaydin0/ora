# Agentic Sunumu
**Date**: Friday, May 15, 2026 at 2:00 PM  
**Duration**: 1:22:17  
**People**: Alen Erboga, Dakika Destek, Emre Osman Çanakçı, Ayyüce Kaytazci, Mehmet Yusuf Taşkın, Mine İşçi, Dilara Coşkun, Onur Taşyıkan, Sarenur COSKUN, Barış Ulaş Önen, Ömer Şahin Özan, Aytuğ Aydoğan, Eren AYDIN, Product_Team, Nursena Bodur, Ömer Işıldak, and Hicret Akkuç

#### Action Items
- [ ] Hicret Akkuç - **Maliyet raporu indirme hatasını Mert'e ilet**
Maliyet raporunu indirirken hata alındı; Mert'e iletilmesi gerekiyor.
- [ ] Hicret Akkuç - **Dakika destek chatbotunu incele ve Tuğçe ile paylaş**
Nursena'nın Dakika destek chatbotu örneğini inceleyip Tuğçe ile paylaşması önerildi; Intercom'un pahalı olduğu ve alternatif aranması gerektiği konuşuldu.
- [ ] Hicret Akkuç - **İşten çıkış ve nakilde meslek kodu zorunluluğunu gözden geçir**
Meslek kodunun işten çıkış ve nakilde tekrar sorulup sorulmaması gerektiği netleştirilmeli; Mehmet'in aktardığı üzere çıkış bildirgelerinde meslek kodu değişmiyor.
- [ ] Hicret Akkuç - **Dakika'dan kalem/değer otomatik çekme yaklaşımını Nursena ile konuş**
Nursena'nın SDP tarafında yaptığı gibi, Dakika üzerindeki tanımlı kalemleri ve değerleri otomatik çekme yaklaşımının Agentic'e nasıl uyarlanabileceği konuşulacak.
- [ ] Hicret Akkuç - **Kalem tanımlamada AI davranışını Tuğçe ile gözden geçir**
Toplantıda tartışıldı: aynı isimde birden fazla kalem varsa AI'ın hangisini seçeceğini sormadan geçmemesi, net/brüt seçeneğini her zaman sorması gerektiği. Tuğçe ile birlikte değerlendirilecek.
- [ ] Hicret Akkuç - **Çalışan unique identifier yapısına karar ver**
Çalışan kimliğini nasıl sunacağına karar verilmesi gerekiyor: isim + iş yeri adı + çalışma ID'si kombinasyonu önerildi. Alen, Mine, Eren ve Mehmet'in geri bildirimleri var.
- [ ] Hicret Akkuç - **Geçmiş dönem değişikliğinde sonraki dönemler için uyarı ekle**
Geçmiş döneme kalem eklendiğinde/çıkarıldığında sonraki dönemlerin yeniden hesaplanması gerektiğine dair uyarı şu an yok. Dilara'nın önerisi.
- [ ] Hicret Akkuç - **AI'a giden verinin dışarı çıkıp çıkmadığını teknik ekiple netleştir**
Barış kodda verinin dışarı çıktığını gördüğünü söyledi; Mert'in aksini söylediği aktarıldı. Yasal risk nedeniyle netleştirilmesi kritik.
- [ ] Hicret Akkuç - **Yıllık düzenli aktarımların dönem akışıyla uyumunu Mehmet ile konuş**
Mehmet'in belirttiği yıllık düzenli aktarımlar (yıllık izin vb.) dönem açma/kapama akışından etkilenebilir; detayı Mehmet anlatacak.
- [ ] Hicret Akkuç - **İşe giriş zorunlu alanlarına doğum tarihini ekle**
İşe giriş zorunlu alanlarına doğum tarihi eklenmesi gerekiyor; BES ve teşvik hesaplamalarında kullanılıyor.
- [ ] Nursena Bodur - **Dakika destek chatbot linkini Hicret'e at**
Hicret'in incelemesi için Dakika destek chatbot linkini atacak.

#### Genel Bakış
* Hicret, Datassist'in Agentic Payroll ürününü (agentic.dakika.com.tr) Datassist ürün ekibine demo etti — ürün henüz canlı müşterisi yok, DocPlanner ile görüşmeler ileri aşamada
* Sistem, HR ve OPS olmak üzere iki rol üzerinden çalışıyor; tüm akışlar (değişiklik, işe giriş, işten çıkış, nakil) ayrı pipeline'larda AI chat üzerinden yürütülüyor
* Toplantıda birkaç kritik açık nokta ortaya çıktı: AI'ya veri çıkışı olup olmadığı netleştirilmeli, kalem seçiminde net/brüt varsayılanı ve benzeri kalemler arasında seçim mekanizması eklenmeli, çalışan kimlik tanımlaması için unique identifier kararlaştırılmalı
* Fiyat: bordro başına **₺200 + KDV**

#### Dashboard ve dönem yönetimi
* Dashboard'da dönem bilgisi, çalışan istatistikleri (toplam, yeni giriş, çıkış), talep özeti ve sorunlar tek ekranda görünüyor
* Dönem yalnızca admin operasyoncular tarafından açılabiliyor — HR, dönem açılmadan veri girişi yapamıyor
* Geçmiş dönemlere (Şubat, Mart, Nisan, Mayıs) geçiş yapılabiliyor; raporlar ve analizler geçmiş dönemler için de çekilebiliyor
* Mehmet, yıllık dönemlerin otomatik açık gelmesinin daha sağlıklı olabileceğini önerdi — yıllık aktarımlar ve düzenli kesintiler için dönem açma/kapama sürecinin sorun yaratabileceğini belirtti

#### Değişiklik isteği ve AI chat
* Tüm değişiklik talepleri AI chat üzerinden doğal dille veya Excel dosyası yükleyerek oluşturuluyor — örneğin "bütün çalışanlarıma 4000 TL altın yardımı tanımla" komutuyla **51** çalışana toplu tanımlama yapıldı
* Değişiklik özeti paneli, yapılan işlemlerin sayısını ve etkilenen çalışanları anlık gösteriyor
* Hatalı oluşturulan taslak talepler chat üzerinden geri alınabiliyor

#### Kalem seçimi ve net/brüt varsayılanı
* Sistemde birden fazla benzer isimli kalem varsa (örn. yemek yardımı nakdi, yemek yardımı kartı) AI şu an rastgele birine atıyor — chat'in seçenekleri listeleyip kullanıcıya sorması gerektiği konusunda ekip hemfikir
* Net/brüt varsayılanı konusunda da ekip, AI'ın her zaman sormasi gerektiği sonucuna vardı — firmalar farklı çalışabiliyor, sabit bir default tanımlamak doğru değil
* Nursena, SDP tarafında da aynı soruyla karşılaştıklarını ve aynı sonuca vardıklarını paylaştı

#### Validasyonlar ve Quick Fix
* Sistem, eksik veya hatalı alanları (yemek yardımı muaf gün sayısı, eksik gün nedeni, net/brüt çakışması) tabloda işaretleyip Quick Fix özelliğiyle doğrudan tablo üzerinden düzeltmeye izin veriyor — chat'e dönmeye gerek kalmıyor
* Toplu güncelleme de mümkün: tüm çalışanlara aynı değeri tek seferde atanabiliyor
* Dilara, geçmiş bir döneme kalem eklendiğinde sonraki dönemlerin yeniden hesaplanması gerektiğine dair bir uyarı mekanizması olmadığını fark etti — Hicret bunu not aldı

#### Çalışan kimlik tanımlama
* Şu an çalışanlar isimle tanımlanıyor; aynı isimde birden fazla çalışan varsa TC kimlik numarası soruluyor
* Birden fazla çalışması olan kişiler için (örn. nakil sonrası iki aktif çalışma kaydı) chat hangi çalışmaya işlem yapılacağını soruyor, iş yeri ID'si gösteriyor
* Ekip, iş yeri ID yerine iş yeri adı ve/veya çalışma ID'sinin birlikte gösterilmesinin daha anlaşılır olacağı konusunda hemfikir — Alen, büyük firmalarda aynı isimde çalışan olabileceğini vurgulayarak unique identifier kararının birlikte verilmesi gerektiğini söyledi

#### Veri güvenliği ve AI'ya veri çıkışı
* Barış, kod reposuna bakarak verinin AI'ya dışarı çıktığını düşündüğünü paylaştı; Hicret ise Mert'le birkaç kez konuştuğunu ve verinin kesinlikle dışarı çıkmadığının teyit edildiğini söyledi — iki taraf arasında çelişki var, netleştirilmesi gerekiyor
* Alen, konu yasal açıdan kritik olduğu için kesin bir cevap alınmadan ürünün dağıtıma çıkarılamayacağını vurguladı
* Barış'ın aktardığına göre ilerleyen versiyonlarda maskeleme veya lokal model seçenekleri planlanıyor; şu anki versiyonda bu yok
* Emre'nin önerdiği "veriyi anonimleştirip gönderme" yaklaşımı da Alen tarafından yasal açıdan sorunlu bulundu

#### HR-OPS onay süreci ve dönem açma
* Değişiklik talepleri HR tarafından oluşturuluyor → OPS onaylıyor veya reddediyor → onaylanan talepler işleme alınıyor
* HR'ın revizyonu olduğunda dönem yeniden açılıyor; taslak talep varlığı OPS'a dönem açma sinyali veriyor
* Hicret, SDP dokümanında dönem açmanın tek seferlik bir işlem olarak geçtiğini görüp kafasının karıştığını belirtti — dönemin her HR revizyonunda açılıp açılmaması gerektiği sorusu açık
* OPS reddettiğinde HR'a neden bildirimi gönderilip gönderilmeyeceği de tartışmaya açık kaldı

#### İşe giriş süreci
* İşe giriş chat üzerinden veya Excel ile yapılabiliyor; zorunlu alanlar (meslek kodu, belge türü, kanun numarası) kırmızıyla işaretleniyor, eksik bırakılınca geçilemiyor
* Şu an **3** belge türü ve birkaç kanun numarası destekleniyor (en son 6111 eklendi); müşteri talebine göre genişletilebilir
* Dilara, doğum tarihinin zorunlu alan olarak eklenmesi gerektiğini vurguladı — BES (**45** yaş kontrolü) ve teşvik hesaplamalarında kullanılıyor; Hicret not aldı
* SGK'ya bağlantı kurulamadığında manuel işe giriş yapılabiliyor: işe giriş bildirgesi PDF olarak yükleniyor

#### İşten çıkış süreci
* İşten çıkış süreci: HR taslak oluşturuyor → önceki dönem bilgisi ve kıdem/ihbar kalemleri giriliyor → OPS bordroyu hesaplıyor → çıkış paketi indiriliyor (hizmet belgesi, ibraname, kıdem/ihbar hesaplamaları, maaş bordrosu) → HR onaylıyor → SGK'ya işleniyor
* Kıdem ve ihbar isteğe bağlı; işten çıkış nedenine göre sistem hak edip etmediğini gösteriyor
* Mehmet, meslek kodunun çıkış bildirgelerinde değil yalnızca giriş bildirgelerinde ve aylık hizmet belgelerinde değiştiğini belirtti — çıkış işlemlerinde meslek kodu sorulmasına gerek olmadığını söyledi; Hicret not aldı

#### Nakil süreci
* Nakil, önce mevcut iş yerinden çıkış sonra yeni iş yerine giriş şeklinde iki adımda işleniyor; ayrı bir pipeline üzerinden yürütülüyor
* Demo sırasında SGK şifresi olmadığı için nakil tamamlanamadı — SGK bağlantısı başarısız olduğunda sistem hata mesajı veriyor

#### Raporlama ve analizler
* Mevcut raporlar (maaş bordrosu, banka raporu, maliyet raporu vb.) şirket veya iş yeri bazlı indirilebiliyor; Excel formatında dışa aktarılabiliyor
* Roadmap'te rapor filtreleme özelliği var: departman bazlı veya maaş eşiğine göre filtrelenmiş raporlar planlanıyor
* Çalışan bazlı rapor görüntüleme ve çalışanlara mail ile bordro gönderme de planlar arasında
* Banka raporunun bankalara özel (Garanti, Akbank vb.) formatlanması da ilerleyen dönemde planlanıyor
* Analiz ekranında demografi, ücret, maliyet, fazla mesai ve işe alım/çıkış sekmeleri var; veriler yalnızca dönem "işlendi" statüsüne geçtikten sonra güncelleniyor

#### Destek ve chatbot
* Şu an destek için Intercom kullanılıyor; AI yanıt özelliği açık değil çünkü her AI yanıtı **$1** kesiyor
* Kimin destek vereceği hâlâ netleşmemiş — ekipte Tuğçe ve Gamze var ama kullanıcı hata yaşadığında süreci kimin yöneteceği belirsiz
* Nursena, Dakika tarafında yardım makalelerini besleyen ve yetmediğinde ticket açan özel bir chatbot geliştirdiklerini paylaştı; Hicret bunu Tuğçe ile paylaşmayı planladı
* Mehmet, mevcut yardım makalelerini içeri gömerek cevap veren, yetmediğinde destek veya ticket'a yönlendiren benzer bir yapı önerdi

#### Müşteri profili, onboarding ve fiyatlandırma
* İki hedef müşteri profili var: mevcut Datassist müşterileri (Agentic'e geçiş) ve Agentic yapısına uygun yeni leadler
* Fiyat bordro başına **₺200 + KDV**; rakip olarak ADP Payroll'un global platformu analiz edildi
* Şu an aktif müşteri yok; DocPlanner ile görüşmeler ileri aşamada
* Onboarding süreci: implementasyon uygunluk değerlendirmesi → eğitim → Datassist tarafında **3** ortam kurulumu
* Nursena, Dakika üzerinde tanımlı kalemlerin ve değerlerin otomatik çekilmesinin implementasyonu kolaylaştırabileceğini önerdi — özellikle mevcut Dakika müşterileri için geçerli
