import 'package:flutter/material.dart';

import '../models/os_info.dart';
import 'settings_page.dart' show nerdFontFamily;
import 'tui.dart';

/// A Font Logos glyph from the bundled Nerd Font, and the colour its badge is
/// filled with: termul's [TuiBrand], by which the badge is drawn.
typedef OsLogo = ({int glyph, Color color});

/// [os]'s brand as termul resolves it: by its `ID`, then what it derives
/// from, then its kernel, so Rocky finds Red Hat's and a Linux with no logo
/// of its own gets Tux. Unknown for a host that has not said, or runs
/// something termul has no brand for.
TuiBrand osBrand(OsInfo? os) => os == null
    ? TuiBrand.unknown
    : TuiBrand.resolve(os.id, idLike: os.idLike, kernel: os.kernel);

/// [os]'s logo, or null where [osBrand] knows none.
OsLogo? osLogo(OsInfo? os) => switch (osBrand(os)) {
  TuiBrand(:final glyph?, :final color) => (glyph: glyph, color: color),
  _ => null,
};

/// The line under a host's name, as Termius writes it: `ssh, me, ubuntu`,
/// or `ssh, me` before the host has said what it runs.
String sshLine(String username, OsInfo? os) =>
    ['ssh', username, ?os?.id].where((part) => part.isNotEmpty).join(', ');

/// A host's OS as termul's [TuiBrandBadge]: a square in the brand's colour
/// with its Font Logos mark, from the bundled Nerd Font, in white; a host
/// that has not said yet, or runs something unknown, gets termul's plain
/// tile. [version] goes under it, and [active] marks a session up.
class OsBadge extends StatelessWidget {
  const OsBadge(
    this.os, {
    super.key,
    this.size = 36,
    this.version,
    this.active = false,
  });

  final OsInfo? os;

  /// The badge's side. The logo scales with it.
  final double size;
  final String? version;
  final bool active;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: TuiBrandBadge(
      brand: osBrand(os),
      size: size,
      version: version,
      active: active,
      reserveVersion: version != null,
      markFontFamily: nerdFontFamily,
    ),
  );
}
