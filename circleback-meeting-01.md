# Agentic payroll product

**Date**: Wednesday, July 29, 2026 at 11:00 AM  
**Duration**: 1:18:29  
**People**: Çağrı Kilit, Osman Baykal, Mert Pamuk, Alen Erboga, and İlknur ÇELİK

#### Action Items

- [ ] Çağrı Kilit - **Pernet ile Agentic Payroll tanıtım toplantısı ayarla** Pernet bu yıl yeni bir yazılım arayışında; Boran ile tanışıklık var. Osman ile birlikte gidip Agentic Payroll'u anlat.
- [ ] İlknur ÇELİK - **Cuma haftalık güncelleme toplantısına Çağrı, Osman ve Alen'i ekle** Umut ile yürütülen haftalık Cuma 15-20 dakikalık güncelleme toplantısına Çağrı, Osman ve Alen'i dahil etmek için daveti paylaş.
- [ ] İlknur ÇELİK - **Webinar lead listesini ve HubSpot iletişim bilgilerini paylaş, müşterileri ara** Webinar sonrası 'ilgileniyorum' diyen ~160 kişilik listeyi ve HubSpot'tan çekilen iletişim bilgilerini Çağrı ve Osman ile paylaş; telefon ile temas kurarak toplantı talep et.
- [ ] Osman Baykal - **Aprico'dan gelen iki potansiyel müşteriyi Agentic Payroll'a yönlendir** Aprico aracılığıyla ulaşılan, İK'cısı olmayan ve bordroyu muhasebeci ile yürütmeye çalışan ~250 ve ~150 kişilik iki firmayı Agentic Payroll sürecine dahil etmek için takip et.
- [ ] Osman Baykal - **Partner adayı firma listesini İlknur'a gönder** Filika'nın geçmişte partner adayı olarak değerlendirdiği, bordro hesaplayan firmaların listesini İlknur'a ilet. İlknur bu listeyi mevcut pipeline'a ekleyecek.
- [ ] Osman Baykal - **Kolay ile Agentic Payroll iş birliği görüşmesini yeniden başlat** Kolay'ın KOBİ tarafındaki temasını yeniden canlandır; daha önce NDA imzalanmıştı.

#### Genel Bakış

- Filika, Datassist'in Agentic Payroll ürününün ([agentic.dakika.com.tr](http://agentic.dakika.com.tr)) derinlemesine teknik demosunu yaptı — dosya yükleme, chat tabanlı veri girişi ve entegrasyon akışlarını kapsadı
- Ürün yaklaşık **1 yıldır** geliştiriliyor; İstihdam'ın **4** firmasının Temmuz bordrolarını Agentic üzerinden işledi, ödemeler **5 Ağustos**'ta gidecek
- Hedef pazar olarak mid-market (150–250 kişilik firmalar) net biçimde öne çıktı — büyük ve kompleks müşteriler SDP'ye bırakılacak
- Webinar sonrası gelen **160** lead'e henüz tam dönüş yapılamadı; İlknur bu listeyi sahiplenip satış sürecini yürütecek
- Partnerlik kanalları (QNB Dijital Köprü, İş Bankası Dijikol, HR yazılımları, SMMM'ler) aktif olarak değerlendiriliyor
- Ürün ve SDP/CDP deneyimlerinin tasarım tutarlılığı açısından yakınlaştırılması gerektiği vurgulandı

#### Ürün demosu

- Mert, "Demo 29 Temmuz A.Ş." şirketi üzerinden tam bir bordro döngüsünü canlı olarak gösterdi — dönem açma, veri girişi, validasyon, operasyoncu onayı ve bordro hesaplama adımlarını kapsadı
- Veri girişi **3** farklı kanaldan yapılabiliyor: dosya yükleme, Luna chat arayüzü ve entegrasyon akışları
- Değişiklik, işe giriş, işten çıkış ve nakil talepleri ayrı akışlar olarak yönetiliyor; her biri HR → operasyoncu onayı → bordro işleme pipeline'ından geçiyor
- Kaynak alanı her değişikliğin nereden geldiğini gösteriyor (kullanıcı, dosya, entegrasyon, Luna mesajı) — ileride entegrasyon logosu ve tarih bilgisi de eklenecek
- Raporlama Luna üzerinden chat ile talep edilebiliyor; analiz ekranında yaş dağılımı, departman/pozisyon bazlı maaş ve toplam işçilik maliyeti (**₺1.588.788,60**) gibi grafikler mevcut

#### Sütun eşleştirme: Levenshtein + AI

- Yüklenen dosyadaki sütun adları için şablon zorunluluğu yok — sistem kendi eşleştiriyor
- Eşleştirme iki aşamalı: önce Levenshtein algoritması (**%85** eşleşme eşiği), kalan alanlar AI'ya gönderiliyor
- AI'ya yalnızca header ve option setleri gönderiliyor, dosya içeriği gönderilmiyor — veri gizliliği korunuyor
- Meslek kodu gibi option sayısı çok yüksek alanlar AI limitlerini aştığı için yalnızca Levenshtein kullanılıyor; Çağrı bu alanda tolerans ayarının iyileştirilmesini önerdi
- Eşleştirmeler "Kalem Eşleştirmeleri" ekranına otomatik kaydediliyor — aynı müşteri sonraki aylarda tekrar eşleştirme yapmak zorunda kalmıyor
- Türkçe karakterler normalize edilmeden Levenshtein'a gönderiliyor; eşleşmeyen alanlar zaten AI'ya düştüğü için sorun yaratmıyor

#### Validasyon kural motoru

- Tüm validasyon kuralları JSON dosyalarında tutuluyor ve no-code stratejiler (lessThan, greaterThan, notEmptyIfPresent, expression vb.) üzerine kurulu
- SMB ve Enterprise için ayrı kural setleri var; her yeni set bir öncekini extend edebiliyor
- HR, validasyon hatası olan bir kaydı operasyoncu onayına gönderemiyor — yanlış bordro hesaplatmanın önüne geçiliyor
- Validasyon hatası oluştuğunda sistem iki seçenek sunuyor: ilgili alanı düzelt veya bağımlı alanı sıfırla
- Alen, ileride firma bazlı kural yönetimi için bir back-office ekranı yapılmasını önerdi; Çağrı bunu validasyon tasarım ekranı olarak back-office'e taşıma fikrini destekledi
- Mevcut durumda kırmızı (hata) uyarıları var; Çağrı sarı (uyarı) seviyesinin de eklenmesini planladıyor

#### Entegrasyon mimarisi (Dock)

- Dock ([dock.filika.co](http://dock.filika.co)) üzerinde sürükle-bırak flow designer ile birden fazla kaynak entegrasyon birleştirilebiliyor
- Farklı kaynaklardan gelen veriler TC kimlik no veya personel sicil no üzerinden merge ediliyor
- Aynı alan birden fazla kaynaktan gelirse entegrasyon sırası önceliği belirliyor — şu an entegrasyon bazlı ezme, ileride değişken bazlı çakışma yönetimi planlanıyor
- Zamanlama seçenekleri: 15 dakika, 30 dakika, 1 saat, 6 saat, 12 saatte bir veya manuel tetikleme
- Entegrasyon verisi Agentic'e geldiğinde sistem çalışanın zaten var olup olmadığını soruyor; yoksa işe giriş mi yoksa taslak çalışan oluşturma mı yapılacağına karar isteniyor
- Çağrı'nın hedefi: dosya yükleme ve chat'i fallback senaryolara indirgemek, verinin **%99**'unu entegrasyonlarla almak

#### Admin ve operasyon paneli

- Yönetim paneli (prod.agentic-admin-ui) tüm şirketlerin dönem pipeline durumunu tek ekranda gösteriyor: Taslak, Açık, Hazır, İşleniyor, Tamamlandı, Kapatıldı
- Talep hacmi kaynağa göre kırılımlı: entegrasyon **296**, Luna **318**, kullanıcı **371** talep
- Toplam hesaplanan bordro sayısı **257**, tamamlanan şirket dönemi **3/8**
- Bordro takvimi (dönem açma, puantaj bitiş, operasyon son işleme, ödeme tarihi) bu panelden yönetiliyor
- İlknur, panelin kimin neyi ne zaman yapıp yapmadığını ve nerede tıkandığını izlemek için kritik olduğunu vurguladı
- Çağrı, Agentic pipeline yapısının SDP'deki implementasyon pipeline'ıyla birebir örtüştüğünü belirtti — iki taraf arasında ortak çalışma fırsatı var

#### Deterministik vs. hibrit AI yaklaşımı

- Alen, büyük ve kompleks firmalardaki süreçlerin deterministik kalması gerektiğini düşünüyor ama hibrit bir modele öncekinden çok daha yakın hissediyor
- Çağrı'nın görüşü: Agentic, bordroyu bilmeyen kullanıcıların (CEO, muhasebeci) kullanabileceği seviyede tasarlandı — Pepsi gibi uç müşteriler bu ürünün kapsamı dışında
- İkisi de SDP ve Agentic'in birkaç yıl içinde yakınlaşacağını öngörüyor; Agentic'i mid-market'e scale etmenin yolu olarak görüyorlar

#### Çok lokasyonlu veri girişi ve puantör rolü

- İlknur, çok lokasyonlu firmalarda (perakende, üretim vb.) puantaj verisinin tek tek mail ile toplandığını ve bu iş yükünün en büyük acı noktası olduğunu paylaştı
- Önerilen model: lokasyon bazlı puantör rolü ile veri girişinin kaynağa dağıtılması, bordro ekibinin verileri tepeden yönetmesi
- Çağrı, IK rolünü puantör gibi alt skoplara bölerek retail odaklı bir ürüne dönüştürmenin mümkün olduğunu söyledi — Ikea bu özelliği özellikle talep etmişti
- Alen, bu modelin farklı rollerdeki kullanıcılara farklı veri giriş ekranları sunduğu global çok lokasyonlu projelerle örtüştüğünü belirtti

#### Hedef pazar: mid-market odağı

- Osman, Aprico aracılığıyla ulaştığı **250** ve **150** kişilik iki firmanın IK'cısı olmadığını ve bordroyu muhasebeci ile yürütmeye çalıştığını aktardı — bunları Agentic'e yönlendirdi
- Çağrı ve Osman, mid-market'in (yaklaşık 150–500 kişi) Agentic için net hedef kitle olduğu konusunda hemfikir — büyük ve kompleks müşteriler SDP'de çözülmeli
- Call center gibi kalabalık ama basit bordrolu firmalar değer açısından cazip değil; kompleks süreç yönetimi gerektiren mid-market firmalar öncelikli
- Osman, bordro uzmanı arayan firmalara LinkedIn üzerinden yazarak Agentic'i alternatif olarak sunmaya başladı — ilk geri dönüşler olumlu

#### Webinar leadleri ve satış süreci

- Agentic webinarından **160** kişi "ilgileniyorum" dedi ama satış ekibinin kaynak kısıtlığı nedeniyle bu listeye tam dönüş yapılamadı
- İlknur bu listeyi HubSpot'tan çekip Tuğçe ile birlikte telefon ile temas kurarak toplantı talep edecek; Osman da bu sürece dahil edilebilir
- Satış ekibi (Selçuk) ürünü yeterli buluyor; tek engel potansiyel müşterilerin "ilk müşteri olmak istememe" çekincesi — referans ihtiyacı var
- Her Cuma **10:30–11:00** arası İlknur ve Umut'un haftalık değerlendirme toplantısı var; Çağrı, Osman ve Alen'in de dahil olması planlanıyor (**Cuma 14:00** sonrası slot değerlendiriliyor)

#### Partnerlik ve dağıtım kanalları

- QNB Dijital Köprü'ye Agentic'i entegre etme planı var, yavaş ilerliyor; paralelde İş Bankası Dijikol ile görüşmeler sürüyor
- HR yazılımları (Teamster, HR Panda) ile panel ortaklığı ana eksen olarak belirlendi — bu firmalar mid-market müşterilerini doğrudan yönlendirebilir
- Pernet bu yıl yeni yazılım arayışında; Çağrı, Osman'ın Bora ile görüşmesini önerdi
- SMMM ve danışmanlık firmaları (BDO önerildi; Big Four ve STG kapsam dışı) ile partner modeli değerlendiriliyor
- Osman, geçmişte NDA imzaladıkları [Kolay.net](http://Kolay.net) ile Agentic Payroll odaklı görüşmeleri yeniden canlandırmayı planlıyor
- İlknur, sanayi odaları, ticaret odaları ve iş birlikleri üzerinden üyelik/ortaklık modeliyle erişim sağlamayı araştırıyor

