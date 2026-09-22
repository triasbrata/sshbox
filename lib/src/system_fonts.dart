import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// A font family installed on this computer, by the name a `fontFamily`
/// finds it by, and whether its platform says every glyph in it is one
/// width — which a terminal's grid needs.
typedef SystemFont = ({String family, bool mono});

/// The font families installed on this computer, monospaced first and each
/// half in alphabetical order; null where they cannot be read, a phone
/// included.
///
/// Asked afresh each time rather than kept, so a font installed while the app
/// runs is there the next time Settings opens. A test puts a list of its own
/// here.
Future<List<SystemFont>?> Function() systemFonts = _read;

Future<List<SystemFont>?> _read() async {
  try {
    // The machine's own platform, not the one a test may pretend to be.
    if (Platform.isLinux) {
      final listed = await Process.run('fc-list', [':', 'family', 'spacing']);
      return listed.exitCode == 0 ? parseFcList(listed.stdout as String) : null;
    }
    if (Platform.isMacOS) {
      // MainFlutterWindow's: NSFontManager's families, and whether any member
      // of each has the fixed-pitch trait.
      final families = await const MethodChannel('sshbox/fonts')
          .invokeListMethod<Map<Object?, Object?>>('families');
      if (families == null) return null;
      return sortedFonts({
        for (final font in families)
          if (font['family'] case final String family)
            family: font['mono'] == true,
      });
    }
    if (Platform.isWindows) return _gdiFonts();
  } on Object {
    // No fc-list, a runner without the channel, or GDI refusing: the list is
    // unknown, which is not the same as empty.
    return null;
  }
  return null;
}

/// The families in what `fc-list : family spacing` prints: a line a face,
/// `DejaVu Sans Mono:spacing=100`, or `DejaVu Sans,DejaVu Sans Condensed` for
/// a proportional face with a second name. A `\` keeps the `-`, `,` or `:`
/// after it in the name, and the first name is the one taken: fontconfig
/// matches a family by any of its names.
///
/// A family is monospaced if any of its faces is, by Pango's rule, which
/// GTK's own font chooser follows: spacing 100 (mono), 90 (dual, a CJK mono
/// font's double-width glyphs) or 110 (charcell).
List<SystemFont> parseFcList(String output) {
  final families = <String, bool>{};
  for (final line in LineSplitter.split(output)) {
    final name = StringBuffer();
    var end = 0;
    for (; end < line.length; end++) {
      final char = line[end];
      if (char == r'\' && end + 1 < line.length) {
        name.write(line[++end]);
      } else if (char == ',' || char == ':') {
        break;
      } else {
        name.write(char);
      }
    }
    final family = name.toString().trim();
    if (family.isEmpty) continue;
    final spacing = _spacing.firstMatch(line.substring(end))?.group(1);
    families[family] =
        (families[family] ?? false) ||
        const {'90', '100', '110'}.contains(spacing);
  }
  return sortedFonts(families);
}

final _spacing = RegExp(r'(?<!\\):spacing=(\d+)');

/// [families] as the picker lists them: monospaced first, then by name
/// whatever its case. A name no one is meant to pick is left out — a Mac's
/// hidden `.` system fonts, and Windows' `@` ones, which are the same fonts
/// turned on their side for vertical text.
List<SystemFont> sortedFonts(Map<String, bool> families) =>
    [
      for (final MapEntry(key: family, value: mono) in families.entries)
        if (!family.startsWith('.') && !family.startsWith('@'))
          (family: family, mono: mono),
    ]..sort(
      (a, b) => a.mono != b.mono
          ? (a.mono ? -1 : 1)
          : a.family.toLowerCase().compareTo(b.family.toLowerCase()),
    );

/// Every family GDI knows, one callback a family and character set.
///
/// A raster font is left out: DirectWrite, where Flutter looks a family up on
/// Windows, draws none. GDI's own pitch, `FIXED_PITCH` in the low bits of
/// `lfPitchAndFamily`, says which are monospaced.
List<SystemFont> _gdiFonts() {
  const rasterFontType = 1;
  const fixedPitch = 1;
  final faces = <String, bool>{};
  final found = NativeCallable<FONTENUMPROC>.isolateLocal((
    Pointer<LOGFONT> font,
    Pointer<TEXTMETRIC> _,
    int type,
    int _,
  ) {
    if (type & rasterFontType == 0) {
      final name = font.ref.lfFaceName;
      faces[name] =
          (faces[name] ?? false) || font.ref.lfPitchAndFamily & 3 == fixedPitch;
    }
    return 1;
  }, exceptionalReturn: 0);
  // A face name left empty and every character set: every family there is.
  final query = (Struct.create<LOGFONT>()..lfCharSet = DEFAULT_CHARSET)
      .toNative();
  final screen = GetDC(null);
  try {
    EnumFontFamiliesEx(screen, query, found.nativeFunction, const LPARAM(0), 0);
  } finally {
    ReleaseDC(null, screen);
    free(query);
    found.close();
  }
  return sortedFonts(withoutGdiStyleNames(faces));
}

/// [faces] less the names GDI gives a weight or width of its own —
/// `Cascadia Mono SemiBold`, `Segoe UI Light`, `Arial Black` — wherever the
/// family they belong to is listed too. DirectWrite, where Flutter looks a
/// family up, folds each of them into that family, so the name alone would
/// find nothing and draw in a fallback; the family is the one to pick, and a
/// terminal draws it in regular and bold only.
@visibleForTesting
Map<String, bool> withoutGdiStyleNames(Map<String, bool> faces) => {
  for (final MapEntry(key: name, value: mono) in faces.entries)
    if (!_styleOfListed(name, faces)) name: mono,
};

// ponytail: an English word list, as GDI's names are; a style word in
// another language keeps its name listed, which at worst draws a fallback.
final _styleWord = RegExp(
  r'\s+((Extra|Ultra|Semi|Demi)?(Light|Bold)|Thin|Hairline|Book|Medium|'
  r'Black|Heavy|(Extra|Ultra|Semi)?(Condensed|Expanded)|Narrow)$',
  caseSensitive: false,
);

bool _styleOfListed(String name, Map<String, bool> faces) {
  for (var rest = name; ;) {
    final base = rest.replaceFirst(_styleWord, '');
    if (base == rest) return false;
    if (faces.containsKey(base)) return true;
    rest = base;
  }
}
