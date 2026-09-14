# Jeansh: listing Play Store (id-ID)

Hanya fitur yang sudah lolos uji pengguna di tablet ("UAT passed" di
CLAUDE.md, Features) per 15 September 2026 yang disebut di sini. Berbagi ke
sesi, browser database, transfer file besar yang lebih cepat, diagram
Mermaid, dan pekerjaan keamanan notifikasi yang masih berjalan menyusul
setelah lolos. Ikon dan feature graphic ada di store/graphics/.

## Nama aplikasi (maks. 30 karakter)

Jeansh: Terminal SSH

## Deskripsi singkat (maks. 80 karakter)

Teman terminal di saku Anda: tab SSH, tmux, pohon file, dan editor kode.

## Deskripsi lengkap (maks. 4000 karakter)

Jeansh adalah terminal SSH untuk ponsel dan tablet Android. Dibuat untuk layar sentuh, dan tetap nyaman dengan keyboard fisik. Sambungkan ke server Anda, buka beberapa sesi sekaligus dalam tab, jelajahi dan edit file-nya, teruskan port, dan terima kabar dari server saat pekerjaan selesai, semuanya dari satu aplikasi.

Terminal
• Tab untuk setiap sesi, beberapa per host; tekan lama sebuah tab untuk menggandakan sesi
• Panel split tmux asli, dinyalakan per host. Jeansh juga menemukan tmux di luar PATH bawaan, seperti yang dipasang Homebrew di Mac
• Bilah tombol berisi Ctrl, Alt, Esc, Tab, dan panah: atur urutannya, hapus tombol, atau tambahkan tombol sendiri di Pengaturan
• Pilih tombol kustom lewat keyboard di layar: tombol apa pun dengan Ctrl, Alt, Shift, atau Super/Cmd, dalam tata letak PC atau macOS
• Magic key: tombol Enter melayang yang membuka dua cincin tombol di bawah jempol Anda (panah, Esc, Tab, Ctrl+C, dan lainnya), dan bersembunyi di tepi layar saat dilempar ke sana
• Tekan lama area kosong lalu geser untuk tombol panah; geser biasa untuk menggulir
• Pilih teks dengan pegangan dan toolbar bawaan sistem
• Ctrl+ketuk sebuah path untuk membukanya, atau sebuah tautan untuk membukanya di tab web di samping shell
• Shift+Enter membuat baris baru dari keyboard fisik
• Mode terang, gelap, atau ikuti sistem, dengan tema Dracula, Nord, Gruvbox, Solarized, Catppuccin, Tokyo Night, dan One Dark untuk aplikasi dan terminal
• Font terminal: Cascadia Mono, Cascadia Code, CaskaydiaCove Nerd Font, JetBrains Mono, dan Fira Code, dengan ukuran sesuai selera

File
• Pohon file untuk setiap server, mulai dari folder pilihan Anda
• Buka folder di terminal, atau biarkan terminal mengikuti folder yang Anda ketuk
• Editor kode dengan nomor baris, warna sintaks, cari dan ganti, lompat ke baris, draf yang tetap ada setelah aplikasi dibuka ulang, serta buka dan simpan dengan sudo
• File Markdown tampil ter-render, dengan sakelar ke teks sumbernya
• Unggah file dari ponsel ke folder mana pun di server, dan unduh file ke ponsel dari pohon file atau dari file yang terbuka di tab

Notifikasi
• Server Anda bisa mengirim notifikasi ke ponsel, misalnya saat build yang lama selesai, dengan skrip shell pendek yang memakai curl dan openssl
• Selama sesi terbuka, notifikasi datang langsung lewat koneksi SSH-nya dan tidak melewati server lain
• Saat tidak ada sesi terbuka, notifikasi lewat relay Jeansh dan Firebase Cloud Messaging. Setiap host punya kunci sendiri: bagian privatnya hanya dikirim ke host itu, relay memeriksa tanda tangan setiap pesan, dan menghapus host akan mencabut kuncinya

Koneksi
• Masuk dengan kata sandi atau private key (OpenSSH atau PEM, dibaca dari file), dengan passphrase
• Jump host, seperti ssh -J
• Port forwarding di layarnya sendiri: tablet ke server (ssh -L) atau server ke tablet (ssh -R), dengan port siap pakai untuk PostgreSQL, MySQL, Redis, dan lainnya
• Server yang Anda jalankan dalam sesi bisa masuk ke tailnet Anda lewat tailscale serve
• Tailscale SSH: halaman masuknya terbuka di samping sesi Anda
• Setiap host menampilkan sistem operasinya lengkap dengan logo, dan Logs menyimpan riwayat sesi Anda

Keamanan
• Host key baru hanya dipercaya setelah Anda melihat fingerprint-nya, dan host key yang berubah ditampilkan lama di samping yang baru
• Known hosts menampilkan setiap fingerprint yang Anda percayai, dan bisa melupakan salah satunya
• Kata sandi, private key, dan passphrase dienkripsi dengan Android Keystore, dan tidak ada data aplikasi yang ikut ke cadangan Google atau transfer perangkat
• Tanpa akun, tanpa iklan, tanpa analitik

Jeansh adalah klien: servernya milik Anda sendiri.
