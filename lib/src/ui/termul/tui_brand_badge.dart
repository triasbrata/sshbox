// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_brand_badge.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';

/// OS or database brand identity for host / DB list rows.
///
/// Marks ship as short mono monograms so Termul stays free of a Nerd Font
/// dependency. Apps that already bundle one (Jeansh) can pass
/// [TuiBrandBadge.markFontFamily] and use [glyph] codepoints.
class TuiBrand {
  const TuiBrand({
    required this.id,
    required this.label,
    required this.color,
    required this.mark,
    this.glyph,
  });

  /// Lookup key — os-release `ID`, `uname`, or DB kind name.
  final String id;
  final String label;

  /// Fill colour — dark enough for a light mark at ≥3:1 contrast.
  final Color color;

  /// 1–2 character monogram drawn when no glyph font is set.
  final String mark;

  /// Optional Nerd Font / Font Logos codepoint (e.g. `0xf31b` Ubuntu).
  final int? glyph;

  // —— OS ——
  static const ubuntu = TuiBrand(
    id: 'ubuntu',
    label: 'Ubuntu',
    color: Color(0xFFE95420),
    mark: 'Ub',
    glyph: 0xf31b,
  );
  static const debian = TuiBrand(
    id: 'debian',
    label: 'Debian',
    color: Color(0xFFD70A53),
    mark: 'De',
    glyph: 0xf306,
  );
  static const arch = TuiBrand(
    id: 'arch',
    label: 'Arch',
    color: Color(0xFF1793D1),
    mark: 'Ar',
    glyph: 0xf303,
  );
  static const fedora = TuiBrand(
    id: 'fedora',
    label: 'Fedora',
    color: Color(0xFF3C6EB4),
    mark: 'Fd',
    glyph: 0xf30a,
  );
  static const centos = TuiBrand(
    id: 'centos',
    label: 'CentOS',
    color: Color(0xFF932279),
    mark: 'Ce',
    glyph: 0xf304,
  );
  static const rhel = TuiBrand(
    id: 'rhel',
    label: 'RHEL',
    color: Color(0xFFEE0000),
    mark: 'Rh',
    glyph: 0xf316,
  );
  static const alpine = TuiBrand(
    id: 'alpine',
    label: 'Alpine',
    color: Color(0xFF0D597F),
    mark: 'Al',
    glyph: 0xf300,
  );
  static const suse = TuiBrand(
    id: 'suse',
    label: 'SUSE',
    color: Color(0xFF4E8A1E),
    mark: 'Su',
    glyph: 0xf314,
  );
  static const manjaro = TuiBrand(
    id: 'manjaro',
    label: 'Manjaro',
    color: Color(0xFF1F8F4A),
    mark: 'Mj',
    glyph: 0xf312,
  );
  static const nixos = TuiBrand(
    id: 'nixos',
    label: 'NixOS',
    color: Color(0xFF5277C3),
    mark: 'Nx',
    glyph: 0xf313,
  );
  static const raspbian = TuiBrand(
    id: 'raspbian',
    label: 'Raspbian',
    color: Color(0xFFC51A4A),
    mark: 'Pi',
    glyph: 0xf315,
  );
  static const freebsd = TuiBrand(
    id: 'freebsd',
    label: 'FreeBSD',
    color: Color(0xFFAB2B28),
    mark: 'FB',
    glyph: 0xf30c,
  );
  static const macos = TuiBrand(
    id: 'macos',
    label: 'macOS',
    color: Color(0xFF6E6E73),
    mark: 'Mc',
    glyph: 0xf302,
  );
  static const windows = TuiBrand(
    id: 'windows',
    label: 'Windows',
    color: Color(0xFF0078D4),
    mark: 'Wn',
    glyph: 0xf17a,
  );
  static const linux = TuiBrand(
    id: 'linux',
    label: 'Linux',
    color: Color(0xFF4B5563),
    mark: 'Lx',
    glyph: 0xf31a,
  );

  // —— Databases ——
  static const postgres = TuiBrand(
    id: 'postgres',
    label: 'PostgreSQL',
    color: Color(0xFF336791),
    mark: 'Pg',
    glyph: 0xe76e,
  );
  static const mongo = TuiBrand(
    id: 'mongo',
    label: 'MongoDB',
    color: Color(0xFF47A248),
    mark: 'Mg',
    glyph: 0xe7a4,
  );
  static const redis = TuiBrand(
    id: 'redis',
    label: 'Redis',
    color: Color(0xFFDC382D),
    mark: 'Rd',
    glyph: 0xe76d,
  );

  /// Host that has not reported an OS yet / unknown brand.
  static const unknown = TuiBrand(
    id: 'unknown',
    label: 'Host',
    color: Color(0xFF5A5A5A),
    mark: '∷',
  );

  static const List<TuiBrand> all = [
    ubuntu,
    debian,
    arch,
    fedora,
    centos,
    rhel,
    alpine,
    suse,
    manjaro,
    nixos,
    raspbian,
    freebsd,
    macos,
    windows,
    linux,
    postgres,
    mongo,
    redis,
  ];

  static final Map<String, TuiBrand> _byId = {
    for (final b in all) b.id: b,
    'darwin': macos,
    'postgresql': postgres,
    'mongodb': mongo,
  };

  /// Resolve from os-release `ID`, then `ID_LIKE` tokens, then kernel name.
  static TuiBrand resolve(
    String? id, {
    String idLike = '',
    String kernel = '',
  }) {
    for (final key in [
      id,
      ...idLike.split(RegExp(r'\s+')),
      kernel.toLowerCase(),
    ]) {
      if (key == null || key.isEmpty) continue;
      final hit = _byId[key.toLowerCase()];
      if (hit != null) return hit;
    }
    if (kernel.toLowerCase().contains('linux') ||
        (idLike.toLowerCase().contains('linux'))) {
      return linux;
    }
    return unknown;
  }
}

/// Sharp brand tile for host / database rows — colour square, monogram (or
/// optional Nerd Font glyph), optional version caption, optional active-session
/// corner mark.
///
/// Prefer over rounded Termius-style badges: Termul chrome is square.
class TuiBrandBadge extends StatelessWidget {
  const TuiBrandBadge({
    super.key,
    this.brand = TuiBrand.unknown,
    this.version,
    this.active = false,
    this.size = 36,
    this.markFontFamily,
    this.reserveVersion = true,
  });

  /// Convenience from os-release fields.
  factory TuiBrandBadge.os({
    Key? key,
    String? id,
    String idLike = '',
    String kernel = '',
    String? version,
    bool active = false,
    double size = 36,
    String? markFontFamily,
  }) {
    return TuiBrandBadge(
      key: key,
      brand: TuiBrand.resolve(id, idLike: idLike, kernel: kernel),
      version: version,
      active: active,
      size: size,
      markFontFamily: markFontFamily,
    );
  }

  final TuiBrand brand;
  final String? version;
  final bool active;
  final double size;

  /// When set (and [TuiBrand.glyph] is non-null), draws the glyph instead of
  /// the monogram — for hosts that ship a Logos / Nerd Font.
  final String? markFontFamily;

  /// Keep a blank version line so badges align in a list even without version.
  final bool reserveVersion;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final known = brand.id != TuiBrand.unknown.id;
    final fill = known ? brand.color : p.surface;
    final border = known ? brand.color : p.border;
    final markColor = known ? Colors.white : (p.isLight ? p.dim : p.text);

    final useGlyph = markFontFamily != null && brand.glyph != null;

    final tile = Semantics(
      label: [
        brand.label,
        if (version != null && version!.isNotEmpty) version,
        if (active) 'active session',
      ].join(', '),
      child: SizedBox(
        width: size,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: fill,
                    border: Border.all(color: border),
                  ),
                  child: useGlyph
                      ? Text(
                          String.fromCharCode(brand.glyph!),
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            fontFamily: markFontFamily,
                            fontSize: size * 0.72,
                            height: 1,
                            color: markColor,
                            decoration: TextDecoration.none,
                          ),
                        )
                      : Text(
                          brand.mark,
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            fontFamily: TermulFonts.mono,
                            fontSize: brand.mark.length > 2
                                ? size * 0.28
                                : size * 0.38,
                            fontWeight: FontWeight.w700,
                            height: 1,
                            color: markColor,
                            decoration: TextDecoration.none,
                          ),
                        ),
                ),
                if (active)
                  Positioned(
                    right: -3,
                    bottom: -3,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: p.accent,
                        border: Border.all(color: p.panel, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            if (version != null || reserveVersion) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: size + 8,
                child: Text(
                  (version == null || version!.isEmpty) ? ' ' : version!,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 9,
                    height: 1.2,
                    color: p.dim,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return tile;
  }
}
