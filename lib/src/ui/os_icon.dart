import 'package:flutter/material.dart';

import '../models/os_info.dart';
import 'settings_page.dart' show nerdFontFamily;

/// A Font Logos glyph from the bundled Nerd Font, and the colour its badge is
/// filled with: the distro's own, dark enough that a white logo on it has 3:1
/// contrast or better.
typedef OsLogo = ({int glyph, Color color});

/// By os-release `ID`, a word of `ID_LIKE`, or `uname -s` in lower case.
const _logos = <String, OsLogo>{
  'ubuntu': (glyph: 0xf31b, color: Color(0xFFE95420)),
  'debian': (glyph: 0xf306, color: Color(0xFFD70A53)),
  'arch': (glyph: 0xf303, color: Color(0xFF1793D1)),
  'fedora': (glyph: 0xf30a, color: Color(0xFF3C6EB4)),
  'centos': (glyph: 0xf304, color: Color(0xFF932279)),
  'rhel': (glyph: 0xf316, color: Color(0xFFEE0000)),
  'alpine': (glyph: 0xf300, color: Color(0xFF0D597F)),
  // openSUSE's IDs are opensuse-leap and the like; all of them say suse.
  'suse': (glyph: 0xf314, color: Color(0xFF4E8A1E)),
  'manjaro': (glyph: 0xf312, color: Color(0xFF1F8F4A)),
  'nixos': (glyph: 0xf313, color: Color(0xFF5277C3)),
  'raspbian': (glyph: 0xf315, color: Color(0xFFC51A4A)),
  'freebsd': (glyph: 0xf30c, color: Color(0xFFAB2B28)),
  'macos': (glyph: 0xf302, color: Color(0xFF6E6E73)),
  'darwin': (glyph: 0xf302, color: Color(0xFF6E6E73)),
  'windows': (glyph: 0xf17a, color: Color(0xFF0078D4)),
  // Tux, for any other Linux.
  'linux': (glyph: 0xf31a, color: Color(0xFF4B5563)),
};

/// [os]'s logo, found by its `ID`, then what it derives from, then its
/// kernel: Rocky finds Red Hat's, and a Linux with no logo of its own gets
/// Tux. Null for a host that has not said, or runs something unknown.
OsLogo? osLogo(OsInfo? os) {
  if (os == null) return null;
  for (final key in [os.id, ...os.idLike.split(' '), os.kernel.toLowerCase()]) {
    if (_logos[key] case final logo?) return logo;
  }
  return null;
}

/// The line under a host's name, as Termius writes it: `ssh, me, ubuntu`,
/// or `ssh, me` before the host has said what it runs.
String sshLine(String username, OsInfo? os) =>
    ['ssh', username, ?os?.id].where((part) => part.isNotEmpty).join(', ');

/// A host's OS as a rounded square in its colour with its logo in white, the
/// way Termius shows one. A host that has not said yet, or runs something
/// without a logo here, gets a plain badge in the theme's colours with a
/// server in it.
class OsBadge extends StatelessWidget {
  const OsBadge(this.os, {super.key, this.size = 40});

  final OsInfo? os;

  /// The badge's side. The logo scales with it.
  final double size;

  @override
  Widget build(BuildContext context) {
    final logo = osLogo(os);
    final scheme = Theme.of(context).colorScheme;

    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: logo?.color ?? scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(size / 4),
        ),
        child: logo == null
            ? Icon(
                Icons.dns,
                size: size * 0.55,
                color: scheme.onSecondaryContainer,
              )
            // Text rather than an IconData: release builds shrink every font
            // a const IconData names down to the glyphs named, and the
            // terminal draws with this one.
            : Text(
                String.fromCharCode(logo.glyph),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: nerdFontFamily,
                  // The Mono font fits a logo into one cell, 0.6 em wide.
                  fontSize: size * 0.95,
                  height: 1,
                  color: Colors.white,
                  // Whatever the page around it says, e.g. no Material.
                  decoration: TextDecoration.none,
                ),
              ),
      ),
    );
  }
}
