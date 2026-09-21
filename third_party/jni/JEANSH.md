# jni 0.14.2, without Windows

Copied from pub.dev's jni 0.14.2 with one change that matters: `windows` is
gone from `flutter.plugin.platforms` in pubspec.yaml, and with it the
windows/ folder. Two things were left out as bulk rather than as a change —
example/, and the build output a local Android build had left in the cache
(android/.cxx). Everything else is the published package as it is.

Also taken out: the `dependency_overrides` block at the end of the published
pubspec, `ffigen: path: ../ffigen`. That is the dart-lang/native monorepo
pointing at a sibling folder which does not exist outside it. Pub ignores a
non-root package's overrides, so it changed nothing either way, but a path
dependency naming a path that is not there is a trap for whoever reads this
next.

Why: jni 0.14.2's C does not compile under MSVC. Building Jeansh for Windows
fails in `jni\src\dartjni.c` and `jni\third_party\jni.h` with dozens of
`error C2059: syntax error: 'string'` and `error C2091: function returns
function`. jni 1.0.3, which this tree had before, does compile there — but
`sentry_flutter` 9.30.0 pins `jni: 0.14.2` exactly, not as a range, and
9.30.0 is the newest stable (above it only 10.0.0-alpha). A pin that tight
means Sentry is built against that exact API, so overriding jni upwards is
not open to us either.

It does not need to be. jni is Java interop: `sentry_flutter` reaches it for
the Android integration, and on Windows there is no JVM for it to reach. The
plugin declared a platform it has no work to do on, and that declaration was
the whole of the breakage.

Linux keeps `ffiPlugin: true` — jni compiles fine under clang there, proven
by a Linux release build — and Android is untouched, being the one platform
that actually uses it.

This is the same shape as third_party/firebase_core beside it: a package
pulled in for one platform whose native half will not build on Windows.

To move to a newer jni, which means a newer sentry_flutter, copy the new
version here the same way and take `windows` out of its pubspec again — or
drop this folder and the override in the root pubspec.yaml altogether if by
then jni builds on Windows and Sentry's pin has moved.
