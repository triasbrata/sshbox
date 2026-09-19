# firebase_core 4.14.0, without Windows

Copied from pub.dev's firebase_core 4.14.0 with one change: `windows` is
gone from `flutter.plugin.platforms` in pubspec.yaml, and with it the
windows/ folder. Everything else is the published package byte for byte.

Why: on Windows the plugin fetches Firebase's prebuilt C++ SDK and links
Jeansh against it, and that SDK was compiled with a newer MSVC than a
Build Tools 2022 17.10 carries, so the link failed on `__std_remove_8`
and two more of the STL's vectorised helpers. Jeansh uses Firebase for
FCM alone, which has no desktop implementation and is switched off on
every desktop build already; desktop notifications come over the SSH
connection. So on Windows the plugin was dead weight that broke the build.

Android, iOS, macOS and web are unchanged. To move to a newer
firebase_core, copy the new version here the same way and take `windows`
out of its pubspec again.
