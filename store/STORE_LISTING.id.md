# Jeansh: listing Play Store (id-ID)

Hanya fitur yang sudah lolos uji pengguna di tablet ("UAT passed" di
CLAUDE.md, Features) yang disebut di sini. Notifikasi dari server, berbagi
ke sesi, dan tombol kustom menyusul setelah lolos.

## Nama aplikasi (maks. 30 karakter)

Jeansh: Terminal SSH

## Deskripsi singkat (maks. 80 karakter)

Teman terminal di saku Anda: tab SSH, tmux, pohon file, dan editor kode.

## Deskripsi lengkap (maks. 4000 karakter)

Jeansh adalah terminal SSH untuk ponsel dan tablet Android. Dibuat untuk layar sentuh, dan tetap nyaman dengan keyboard fisik. Sambungkan ke server Anda, buka beberapa sesi sekaligus dalam tab, jelajahi dan edit file-nya, serta teruskan port, semuanya dari satu aplikasi.

Terminal
• Tab untuk setiap sesi, beberapa per host; tekan lama sebuah tab untuk menggandakan sesi
• Panel split tmux asli, dinyalakan per host
• Bilah tombol berisi Ctrl, Alt, Esc, Tab, dan panah, yang urutan dan isinya bisa diatur di Pengaturan
• Magic key: tombol Enter melayang yang membuka dua cincin tombol di bawah jempol Anda (panah, Esc, Tab, Ctrl+C, dan lainnya), dan bersembunyi di tepi layar saat dilempar ke sana
• Tekan lama area kosong lalu geser untuk tombol panah; geser biasa untuk menggulir
• Pilih teks dengan pegangan dan toolbar bawaan sistem
• Ctrl+ketuk sebuah path untuk membukanya, atau sebuah tautan untuk membukanya di tab web di samping shell
• Shift+Enter membuat baris baru dari keyboard fisik
• Mode terang, gelap, atau ikuti sistem, dengan tema Dracula, Nord, Gruvbox, Solarized, Catppuccin, Tokyo Night, dan One Dark untuk aplikasi dan terminal
• Font terminal: Cascadia Mono, Cascadia Code, CaskaydiaCove Nerd Font, JetBrains Mono, dan Fira Code, dengan ukuran sesuai selera

File
• Pohon file ala VS Code untuk setiap server, mulai dari folder pilihan Anda
• Buka folder di terminal, atau biarkan terminal mengikuti folder yang Anda ketuk
• Editor kode dengan nomor baris, warna sintaks, cari dan ganti, lompat ke baris, draf yang tetap ada setelah aplikasi dibuka ulang, serta buka dan simpan dengan sudo
• File Markdown tampil ter-render, dengan sakelar ke teks sumbernya
• Unggah file dari ponsel ke folder mana pun di server, dan unduh file ke ponsel

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
