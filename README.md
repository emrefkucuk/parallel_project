# Dinamik İki Katmanlı Paralel Malware Tarayıcı (CENG479)

Bu repo, **CENG479 Parallel Programming** dersi için hazırladığımız proje implementasyonudur.
Temel işleyiş aşağıda belirtildiği gibidir:

- Disk I/O’yu ölçümden çıkarmak için dosyayı **memory-map** etmek
- CPU üzerinde **paylaşımlı bellek** modelinde paralel tarama yapmak
- Irregular iş yükünde thread starvation’ı azaltmak için **ForkJoinPool work-stealing** kullanmak
- İki aşamalı bir tarama pipeline’ı kurmak:
  - **Tier 1 (hızlı filtre)**: byte seviyesinde **rolling hash (Rabin–Karp)**
  - **Tier 2 (kesin doğrulama)**: sıfırdan **Aho–Corasick DFA** ile exact eşleşme

---

## Takım

- 22118080039 — Emre Faruk Küçük
- 22118080058 — Yusuf Taha Sarıtiken

---

## Proposal ve Repo Farkları

Proposal’daki bazı noktalar pratikte karar gerektiriyordu. Biz şu şekilde sabitledik:

- **ClamAV imzalarında wildcard konusu**  
  - Proposal Tier 2’de *Aho–Corasick DFA* kullanılacağı ifade ediliyor.  
  - ClamAV `.ndb` içinde `?`, `*`, `{n-m}` gibi wildcard/metakarakterli imzalar var.  
  - **Karar**: Repo, yalnızca **wildcard içermeyen saf HEX** imzaları yüklüyor.  
    Böylece Tier 2 gerçekten DFA olarak kalıyor ve proposal ile birebir örtüşüyor.

- **İmza sayısı karışıklığı**  
  - Proposal: trie’de on binlerce imza hedefliyor.  
  - Doğruluk testi için ayrıca payload’a bilinen offset’lere imza gömmek gerekiyor.  
  - **Karar**:
    - Trie / signature set: `main_subset.ndb` içinde **50.000** imza
    - Sentetik payload: bu imzalardan seçilmiş **200 seed** imza bilinen offset’lere enjekte ediliyor
    - Böylece hem proposal’daki ölçek korunuyor hem de ground-truth doğrulama yapılabiliyor.

- **Proposaldaki karşılaştırma zorunluluğu**  
  - Proposal sadece sequential baseline'ın yanı sıra **static, single-tier parallel** ile
    **work-stealing** in karşılaştırılmasını istiyor.  
  - **Karar**: İki paralel mod var:
    - `dynamic`: `ForkJoinPool` work-stealing
    - `static`: `ExecutorService` ile sabit chunk dağıtımı

- **Proposal metrik seti**  
  - Proposal: speedup + efficiency + throughput (GB/s) + idle time + steal count + (opsiyonel) HW counters.  
  - **Karar**: Benchmark çıktısı JSON/CSV + grafikler + `notes.md` olarak bundle içinde üretiliyor.
    HW counter kısmı için (L1/L2 miss, stall cycles) harici profiler gerekiyor; bkz. `scripts/README.md`.

---

## Proje Pipeline'ı

### 1) İmza yükleme (`.ndb`)

- Varsayılan imza dosyası: `src/main/resources/signatures/main_subset.ndb`
- `SignatureLoader`, `.ndb` satırlarını parse eder ve **sadece saf HEX** imzaları alır.
- `SignatureSet` oluşturulur:
  - Tier 1 için rolling-hash tablosu
  - Tier 2 için Aho–Corasick DFA

### 2) Payload’ı pre-load etmek (I/O’yu ölçümden ayırmak)

- Payload dosyası **memory-map** edilir ve **read-only** taranır.
- Benchmark sırasında süre ölçümü, mapping tamamlandıktan sonra başlar.

### 3) Chunking + overlap (N-1 kuralı)

- Payload mantıksal chunk’lara bölünür.
- **En uzun imza uzunluğu \(N\)** ise her chunk, kendi aralığına ek olarak **\(N-1\)** byte overlap okur.
- Böylece bir imza chunk sınırını geçse bile en az bir thread tarafından yakalanır; inter-thread lock gerekmez.

### 4) Tier 1 → Tier 2 pipeline

- Her chunk üzerinde önce **rolling hash** ile hızlı tarama yapılır.
- Hash collision olursa o offset’te **Aho–Corasick** ile kesin doğrulama yapılır.

### 5) Paralellik (dynamic ve static)

- `dynamic`: `ForkJoinPool` + work-stealing 
- `static`: sabit dağıtım

---

## Paralel Programlama

Bu projede paralel programlama 3 ana yerde “çekirdek özellik” olarak kullanılıyor:

### 1) Dinamik İş Dağıtımı: `ForkJoinPool` ve Work-Stealing

Projede, iş parçacıkları (thread) arasındaki düzensiz yük dağılımını dengelemek amacıyla Java'nın **work-stealing** algoritmasını temel alan `ForkJoinPool` yapısı kullanılmaktadır. Zararlı yazılım (malware) imzalarının dosya içerisindeki dağılımı ve Tier 2 aşamasına geçiş sıklığı rastgele olabildiğinden, bazı veri bloklarının (chunk) taranması diğerlerinden daha uzun sürebilir. Bu düzensiz (irregular) iş yükünde kaynak israfını (thread starvation) önlemek için payload çok sayıda küçük iş parçasına bölünür. Bir iş parçacığı kendi kuyruğundaki işlemleri bitirdiğinde, boşta beklemek yerine diğer iş parçacıklarının kuyruğundan iş alarak (çalma - steal) CPU'nun maksimum verimde kullanılmasını sağlar. Benchmark testlerinde toplanan `stealCount` metriği sayesinde iş yükü dağılımındaki dengesizlik analiz edilebilmektedir.

### 2) Statik Paralel Baseline

Proposal'da hedeflenen performans artışını ölçebilmek adına `ExecutorService` kullanılarak tasarlanmış, iş parçacıkları arasında dinamik yük paylaşımının olmadığı bir karşılaştırma modeli (baseline) sunulmaktadır. Bu yapıda, taranacak dosya baştan iş parçacığı sayısı kadar eşit parçaya bölünür. Görevini erken bitiren bir iş parçacığı boşa çıkar (idle) ve diğerlerinin işine yardımcı olmaz. Bu yaklaşım, dinamik iş dağıtımının avantajlarını (özellikle work-stealing algoritmasının "idle time" üzerindeki etkilerini) kıyaslamak amacıyla eklenmiştir.

### 3) Sınır Problemi: N-1 Overlap ile Lock-Free Doğruluk

Paralel çalışan iş parçacıklarının tamamen bağımsız hareket edebilmeleri (inter-thread lock zorunluluğunu ortadan kaldırmak) için, tarama işlemi yapılacak veri blokları bir miktar örtüşecek (overlap) şekilde tasarlanmıştır. Veri kümesindeki en uzun imza boyutunun \(N\) olduğu baz alındığında, her thread kendi chunk aralığına ek olarak komşu bölümün \(N-1\) bytelık kısmını da taramaya dahil eder. Bu sayede blok sınırlarına denk gelen imzaların gözden kaçırılması engellenir. Analiz sonrası eşleşen bulgular, asıl bloğa ait olup olmama filtresinden geçirilerek aynı hit'in tekrarlı olarak kaydedilmesinin önüne geçilir.

### 4) Paylaşımlı Bellek ve Lock-Free Yaklaşım

Performansı maksimize etmek için taranacak dosya belleğe read-only olarak eşlenir (`MappedByteBuffer`). Bu sayede tüm thread'ler veri kaynağına kilitlenmelere (locking) maruz kalmadan aynı anda erişebilir. Tespit edilen zararlı yazılım imzaları, süreç içerisinde kilit kullanımından kaçınmak amacıyla lock-free veri yapılarında toplanarak eşzamanlı erişim kaynaklı yavaşlamalar engellenir.

### 5) Paralel performans metrikleri

Benchmark şu metrikleri üretir (CSV/JSON + grafik):

- **Speedup**: \(S = T_s / T_p\)
- **Efficiency**: \(E = S / p\)
- **Throughput**: MB/s (raporda GB/s’ye çevrilebilir)
- **Idle time**: thread’lerin boşta kaldığı süre tahmini
- **Steal count**: work-stealing operasyon sayısı

Donanım sayaçları (L1/L2 miss, stall cycles) için harici profiler gerekir: [`scripts/README.md`](scripts/README.md).

---


## Docker ile Çalıştırma

Projeyi herhangi bir sisteme (Java, Maven vb.) bağımlı kalmadan, platform bağımsız bir şekilde Docker üzerinde çalıştırabilirsiniz. İmaj içerisinde GUI desteği (noVNC) bulunmaktadır, böylece tarayıcı üzerinden uygulamanın arayüzüne erişebilirsiniz.

### Ön Koşullar
Sisteminize uygun Docker versiyonunun kurulu olması gerekmektedir:
- **Windows / macOS**: [Docker Desktop](https://www.docker.com/products/docker-desktop/) kurulu ve uygulamanın arka planda çalışıyor olması gerekmektedir.
- **Linux**: Docker Engine ve Docker Compose kurulu olmalı, ayrıca mevcut kullanıcınız tercihen `docker` grubuna dahil edilmiş olmalıdır.

### İşletim Sistemine Göre Çalıştırma Adımları

#### Windows

```cmd
docker compose up --build
```

#### macOS

```bash
docker compose up --build
```

#### Linux

```bash
docker compose up --build
```

### Arayüze (GUI) Erişim

Konteyner başarıyla ayağa kalktıktan sonra (işletim sisteminden bağımsız olarak) web tarayıcınızdan aşağıdaki adrese giderek uygulamanın arayüzüne ulaşabilirsiniz:
**http://localhost:8080/vnc.html**

---


## Gereksinimler

- **JDK 17+**
- **Apache Maven 3.9+**
- (Opsiyonel) **JDK Mission Control (JMC)**: `.jfr` dosyasını açmak için  
  `jmc -open report\\bench-....jfr`
- (Opsiyonel) HW counters için profiler: Intel VTune / AMD uProf / Linux perf  
  Detay: [`scripts/README.md`](scripts/README.md)

---

## Build

```bat
mvn clean package
```

Çıktı (runnable jar):

```bat
target\\parallel-malware-scanner.jar
```
---

## Grafiksel Kullanıcı Arayüzü (GUI) ile Çalıştırma

Projeyi derledikten sonra aşağıdaki komutla arayüzü başlatabilirsiniz:

```bat
java -jar target\parallel-malware-scanner.jar
```

Uygulama arayüzü temel olarak iki bölümden oluşmaktadır:

- **Tarama (Scan) Modülü**: Kullanıcıların imza veritabanını ve incelenecek veri dosyasını (payload) seçmesine olanak tanır. Tarama sürecinde kullanılacak aktif iş parçacığı (thread) sayısı ve veri bloğu büyüklüğü (chunk threshold) gibi parametreler ayarlanarak analiz başlatılabilir. İşlem sonlandığında, eşleşen zararlı yazılım imzalarının (hit) detaylı listesi ekrana yansıtılır.
- **Performans Analizi (Benchmark) Modülü**: Uygulamanın farklı iş parçacığı sayılarında (ör. 1, 2, 4, 8, 16) sergilediği tarama performansını test etmeyi sağlar. Dinamik (work-stealing) ve statik görev dağıtımı modellerinin karşılaştırmalı analizini yapar, elde edilen hızlanma (speedup) ve verimlilik (efficiency) değerlerini grafiksel olarak sunar ve verilerin dışa aktarılmasına imkân tanır.

---

## Komut Satırı (CLI) ile Analiz ve Raporlama

Özellikle büyük veri setleriyle gerçekleştirilecek tekrarlı performans ölçümlerinde arayüz bağımlılığını ortadan kaldırmak için hazırlanan CLI betikleri kullanılabilir.

**Standart Kullanım:**
Örneğin 1024 MB boyutunda rastgele oluşturulmuş bir test verisiyle (payload) varsayılan analizi başlatmak için:

```bat
scripts\run-bench.bat 1024
```

**Özelleştirilmiş Thread Konfigürasyonu:**
Test sürecini önceden belirlenmiş belirli iş parçacığı kombinasyonlarında çalıştırmak isterseniz listeyi argüman olarak verebilirsiniz:

```bat
scripts\run-bench.bat 1024 1;2;4;8;16 skewed
```

> [!WARNING]
> **Windows İşletim Sistemi İçin Önemli Not**: Windows Komut Satırı'nda (CMD) argüman geçişlerinde virgül (`,`) karakteri batch betiklerinin parametre ayrıştırmasını bozabilmektedir. Bu nedenle birden fazla thread konfigürasyonu girerken değerler arasında daima **noktalı virgül** (`;`) kullanılmalıdır.

**Oluşturulan Çıktılar ve Raporlar:**
Benchmark işlemi tamamlandığında, uygulamanın kök dizinindeki `report\` klasörü altında kapsamlı ölçüm verileri derlenir:

- `bench-<etiket>-<zaman>.json` — Test sonrasında elde edilen ham metrikleri barındıran veri dosyası.
- `bench-<etiket>-<zaman>.jfr` — İş parçacığı (thread) durumlarını, JIT derleme aşamalarını, bellek kullanımını ve metod düzeyinde CPU profilini barındıran detaylı JFR (Java Flight Recorder) analiz kaydı.
- `bundle-<etiket>-<zaman>\` — Test sonuçlarının derlendiği toplu rapor klasörü:
  - `benchmark_full.csv` — Karşılaştırmalı tüm analiz verilerini içeren özet tablo.
  - `charts\` — İlgili değerlendirme metriklerinin (throughput, speedup, efficiency, idle time) oluşturulan görsel grafikleri.
  - `notes.md` — Ölçümler baz alınarak otomatik şekilde üretilen değerlendirme ve yorum dosyası.

---


## Kod Yapısı (kısa)

- `src/main/java/com/malwarescan/engine/` — `SignatureLoader`, `RollingHash`, `AhoCorasick`, `SignatureSet`
- `src/main/java/com/malwarescan/scanner/` — sequential/dynamic/static tarama çekirdeği
- `src/main/java/com/malwarescan/benchmark/` — benchmark runner + report bundle üretimi
- `src/main/java/com/malwarescan/gui/` — Scan/Benchmark tab’ları + chart’lar
- `src/test/java/com/malwarescan/` — unit testler
