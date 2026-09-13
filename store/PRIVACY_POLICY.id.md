# Kebijakan Privasi Jeansh

**Tanggal berlaku:** 14 September 2026

**Terakhir diperbarui:** 14 September 2026

## Ringkasan

Jeansh adalah klien SSH. Aplikasi ini tersambung langsung dari perangkat Anda
ke server yang Anda tambahkan. Apa pun yang Anda ketik, baca, unggah, atau
edit dalam sesi tidak melewati server kami.

Hanya satu hal yang sampai ke kami: token notifikasi push perangkat Anda.
Aplikasi menukarnya ke relay notifikasi kami dengan sebuah kunci yang dipakai
server Anda untuk mengirim notifikasi. Tidak ada akun, iklan, analitik,
maupun laporan crash.

## Yang tetap di perangkat Anda

Jeansh menyimpan hal-hal berikut di penyimpanan privat aplikasi di perangkat
Anda:

- **Host:** untuk setiap host yang disimpan, nama, alamat, port, nama
  pengguna, cara masuk, jump host, folder pohon file, sakelar tmux dan
  penerusan tailnet, serta sistem operasi yang dilaporkan server pada koneksi
  terakhir.
- **Rahasia:** kata sandi, private key, dan passphrase, dienkripsi dengan
  kunci yang disimpan di Android Keystore. Di iOS disimpan di Keychain, hanya
  di perangkat ini.
- **Known hosts:** fingerprint host key yang sudah Anda percayai.
- **Logs:** riwayat sesi Anda, berisi host serta kapan setiap sesi dimulai
  dan berakhir.
- **Port forward:** port yang Anda atur di layar Port forwarding.
- **Draf:** suntingan yang belum disimpan pada file server di editor kode,
  hingga 256 KB per file, disimpan sampai Anda menyimpan atau membuangnya.
- **Pengaturan:** tema, font, bilah tombol, posisi magic key, dan tampilan
  editor.
- **Kunci notifikasi:** kunci relay yang dijelaskan di bawah, beserta token
  yang dipakai untuk menerbitkannya, dienkripsi seperti rahasia di atas.
- **Tab web:** halaman yang Anda buka di tab web, misalnya halaman masuk
  Tailscale, menyimpan cookie dan cache-nya di penyimpanan web view aplikasi.

Aplikasi mematikan cadangan cloud Google dan transfer antarperangkat, jadi
tidak ada data di atas yang keluar lewat jalur itu. Menghapus penyimpanan
aplikasi, atau mencopot aplikasinya, menghapus semuanya.

## Yang dikirim ke server Anda

Semua yang Anda lakukan dalam sesi dikirim ke server yang sedang tersambung,
lewat SSH, dan dienkripsi antara perangkat Anda dan server itu. Termasuk:

- apa yang Anda ketik, dan apa yang ditampilkan server;
- file yang Anda unggah, buka, atau unduh. File yang diunduh disimpan di
  tempat yang Anda pilih di dialog simpan sistem;
- perintah yang dijalankan aplikasi untuk Anda di sana: membaca sistem operasi
  server, memantau server yang Anda jalankan saat penerusan tailnet menyala,
  dan tmux.

Setiap shell juga menerima empat variabel lingkungan:

- `LC_SSHBOX_TOKEN`: kunci notifikasi Anda;
- `LC_SSHBOX_HOST_ID`: id host yang disimpan;
- `LC_SSHBOX_NOTIFY_URL` dan `LC_SSHBOX_NOTIFY_SECRET`: untuk notifikasi
  langsung lewat koneksi itu.

Server tersebut milik Anda, atau pilihan Anda. Kami tidak pernah menerima apa
yang dikirim ke sana.

## Notifikasi

Server yang Anda pakai bisa mengirim notifikasi ke ponsel Anda dengan dua cara.

**Langsung lewat koneksi.** Selama sesi terbuka, server bisa memberi tahu Anda
lewat koneksi SSH itu sendiri. Notifikasi ini tidak melewati Google maupun
server kami.

**Lewat relay kami**, yang juga berfungsi saat tidak ada sesi terbuka:

- Saat dibuka, aplikasi mendaftar ke **Firebase Cloud Messaging** (FCM),
  layanan push Google, yang memberi perangkat sebuah token pendaftaran. Google
  memprosesnya menurut [Kebijakan Privasi Google](https://policies.google.com/privacy)
  dan [ketentuan privasi Firebase](https://firebase.google.com/support/privacy).
- Aplikasi mengirim token itu ke **jeansh-notify**, relay kami di
  `jeansh-notify.brata.cloud` (sebuah Cloudflare Worker), dan menerima sebuah
  kunci notifikasi acak. Ini diulang hanya saat FCM mengganti tokennya.
- Relay menyimpan satu entri per kunci, di Cloudflare Workers KV: hash
  SHA-256 dari kunci itu, yang menunjuk ke token FCM dan waktu pembuatannya.
  Kuncinya sendiri tidak disimpan, dan relay tidak pernah mencatat kunci,
  token, maupun pesan ke log.
- Saat server mengirim notifikasi dengan kunci itu, relay meneruskan judul,
  isi, dan id host ke FCM, yang mengantarkannya ke perangkat Anda. Relay tidak
  menyimpan apa pun dari pesannya.
- Relay menghitung pendaftaran per alamat IP untuk mencegah penyalahgunaan,
  dan tidak menyimpan alamat itu. Cloudflare, yang menjalankan relay,
  memproses data permintaan seperti alamat IP menurut
  [Kebijakan Privasi Cloudflare](https://www.cloudflare.com/privacypolicy/).

**Menghapus entri di relay.** Ada tiga cara:

- **Pengaturan → Notifikasi → Reset notification key** menghapus entri relay
  untuk kunci Anda dan menerbitkan kunci baru.
- Saat FCM melaporkan bahwa token tidak berlaku lagi, misalnya setelah
  aplikasi dicopot, relay menghapus entrinya saat ada server yang mencoba
  memakainya.
- Untuk menghapus entri tanpa menerbitkan kunci baru, kirimkan kunci Anda
  lewat email kepada kami, dari **Pengaturan → Notifikasi → Copy notification
  key**.

## Yang tidak kami kumpulkan

Kami tidak mengumpulkan:

- nama, alamat email, atau akun apa pun;
- lokasi atau kontak Anda;
- ID iklan;
- analitik atau laporan crash.

Aplikasi tidak memuat Firebase Analytics maupun Crashlytics. Selain SSH ke
server Anda, FCM, dan relay, aplikasi hanya tersambung ke halaman web yang
Anda buka di tab web.

## Berbagi data

Kami tidak menjual atau membagikan data Anda. Google (untuk FCM) dan
Cloudflare (yang menjalankan relay) memprosesnya hanya untuk mengantarkan
notifikasi.

## Izin Android

- **Internet** dan **status jaringan:** koneksi SSH, notifikasi, dan tab web.
- **Notifikasi:** notifikasi dari server Anda, dan notifikasi tetap selama
  sesi terbuka.
- **Layanan latar depan (sinkronisasi data)** dan **wake lock:** menjaga sesi
  dan port forward yang terbuka tetap tersambung saat aplikasi di latar
  belakang.
- **Menerima pesan push** (`com.google.android.c2dm.permission.RECEIVE`):
  pengiriman lewat FCM.
- **Berjalan saat perangkat menyala** (`RECEIVE_BOOT_COMPLETED`): dideklarasikan
  oleh pustaka layanan latar depan untuk opsi mulai-ulang saat boot, yang
  dimatikan oleh Jeansh. Tidak ada yang berjalan saat ponsel dinyalakan.
- **Getar:** dideklarasikan oleh pustaka notifikasi, untuk notifikasi.

## Anak-anak

Jeansh adalah alat untuk orang yang mengurus server. Aplikasi ini tidak
ditujukan untuk anak-anak.

## Keamanan

SSH mengenkripsi setiap sesi. Aplikasi bertanya dulu sebelum memercayai host
key baru, dan memperingatkan saat host key yang sudah dikenal berubah. Rahasia
dienkripsi dengan Android Keystore. Relay hanya menyimpan hash dari setiap
kunci.

## Hak dan pilihan Anda

- **Di perangkat Anda:** cabut izin notifikasi di pengaturan Android kapan
  saja. Hapus penyimpanan aplikasi, atau copot aplikasinya, untuk menghapus
  semua yang disimpan aplikasi.
- **Di relay:** entri relay adalah satu-satunya data Anda yang kami simpan.
  Untuk meminta salinan atau penghapusannya, termasuk berdasarkan GDPR atau
  CCPA, kirim email kepada kami beserta kunci dari **Pengaturan → Notifikasi →
  Copy notification key**.

## Perubahan kebijakan ini

Saat kebijakan ini berubah, tanggal "Terakhir diperbarui" di atas ikut
berubah.

## Kontak

Email: triasbrata@gmail.com
