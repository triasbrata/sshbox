// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_menu.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// A control's Semantics is its own node (container: true), so its word is
// not merged into whatever is around it: a screen reader, an e2e flow and a
// finder can each reach it by that word.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'termul_palette.dart';
import 'termul_theme.dart';

/// An entry in a [showTuiMenu] panel — action or separator.
sealed class TuiMenuEntry<T> {
  const TuiMenuEntry();
}

/// A tappable menu row.
class TuiMenuItem<T> extends TuiMenuEntry<T> {
  const TuiMenuItem({
    required this.value,
    required this.label,
    this.shortcut,
    this.enabled = true,
    this.destructive = false,
    this.checked,
  });

  final T value;
  final String label;

  /// Optional mono hint on the trailing edge (`⌘C`, `del`, …).
  final String? shortcut;
  final bool enabled;

  /// Uses deep/danger ink instead of accent hover.
  final bool destructive;

  /// When non-null, draws a leading check mark when true.
  final bool? checked;
}

/// Hairline divider between groups.
class TuiMenuDivider<T> extends TuiMenuEntry<T> {
  const TuiMenuDivider();
}

/// Opens a Termul popup / context menu.
///
/// Pass [at] (global coordinates) for pointer/long-press placement, or
/// [anchor] to open below a widget (overflow menu). Prefer one of the two.
Future<T?> showTuiMenu<T>(
  BuildContext context, {
  Offset? at,
  RelativeRect? position,
  BuildContext? anchor,
  required List<TuiMenuEntry<T>> entries,
  double minWidth = 180,
  double maxWidth = 280,
}) {
  assert(
    at != null || position != null || anchor != null,
    'showTuiMenu needs at, position, or anchor',
  );

  final p = TermulThemeData.of(context).palette;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;

  RelativeRect rect;
  if (position != null) {
    rect = position;
  } else if (at != null) {
    final local = overlay.globalToLocal(at);
    rect = RelativeRect.fromRect(local & Size.zero, Offset.zero & overlay.size);
  } else {
    final box = anchor!.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    rect = RelativeRect.fromRect(
      Rect.fromLTWH(topLeft.dx, topLeft.dy + size.height, size.width, 0),
      Offset.zero & overlay.size,
    );
  }

  return showMenu<T>(
    context: context,
    position: rect,
    elevation: 0,
    color: p.panel,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.transparent,
    shape: RoundedRectangleBorder(side: BorderSide(color: p.border)),
    constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
    items: [for (final entry in entries) _toPopupEntry(entry, p)],
  );
}

PopupMenuEntry<T> _toPopupEntry<T>(TuiMenuEntry<T> entry, TermulPalette p) {
  return switch (entry) {
    TuiMenuDivider() => PopupMenuDivider(height: 9, color: p.border),
    TuiMenuItem(
      :final value,
      :final label,
      :final shortcut,
      :final enabled,
      :final destructive,
      :final checked,
    ) =>
      PopupMenuItem<T>(
        value: value,
        enabled: enabled,
        height: 36,
        padding: EdgeInsets.zero,
        child: _TuiMenuRow(
          label: label,
          shortcut: shortcut,
          enabled: enabled,
          destructive: destructive,
          checked: checked,
        ),
      ),
  };
}

class _TuiMenuRow extends StatelessWidget {
  const _TuiMenuRow({
    required this.label,
    this.shortcut,
    required this.enabled,
    required this.destructive,
    this.checked,
  });

  final String label;
  final String? shortcut;
  final bool enabled;
  final bool destructive;
  final bool? checked;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final Color fg;
    if (!enabled) {
      fg = p.dim;
    } else if (destructive) {
      fg = p.isLight ? p.deep : p.red;
    } else {
      fg = p.text;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: checked == null
                ? null
                : Text(
                    checked! ? '✓' : '',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 12,
                      color: p.accent,
                      height: 1,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: fg,
                height: 1.25,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (shortcut != null) ...[
            const SizedBox(width: 16),
            Text(
              shortcut!,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 11,
                color: p.dim,
                height: 1.25,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Overflow / ⋮ button that opens a [showTuiMenu] below itself.
class TuiMenuButton<T> extends StatelessWidget {
  const TuiMenuButton({
    super.key,
    required this.entries,
    this.onSelected,
    this.tooltip = 'Menu',
    this.icon = '⋮',
    this.enabled = true,
  });

  final List<TuiMenuEntry<T>> entries;
  final ValueChanged<T>? onSelected;
  final String tooltip;
  final String icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Builder(
      builder: (buttonContext) {
        return Semantics(
          container: true,
          button: true,
          enabled: enabled,
          label: tooltip,
          child: InkWell(
            onTap: !enabled
                ? null
                : () async {
                    final selected = await showTuiMenu<T>(
                      context,
                      anchor: buttonContext,
                      entries: entries,
                    );
                    if (selected != null) onSelected?.call(selected);
                  },
            hoverColor: p.selection,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: ExcludeSemantics(
                  child: Text(
                    icon,
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 16,
                      height: 1,
                      color: enabled ? p.text : p.dim,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Wraps [child] so long-press (touch) and secondary-click (desktop) open a
/// Termul context menu at the pointer.
class TuiContextMenuRegion<T> extends StatefulWidget {
  const TuiContextMenuRegion({
    super.key,
    required this.entries,
    required this.child,
    this.onSelected,
    this.enabled = true,
  });

  final List<TuiMenuEntry<T>> entries;
  final Widget child;
  final ValueChanged<T>? onSelected;
  final bool enabled;

  @override
  State<TuiContextMenuRegion<T>> createState() =>
      _TuiContextMenuRegionState<T>();
}

class _TuiContextMenuRegionState<T> extends State<TuiContextMenuRegion<T>> {
  Offset? _lastGlobal;

  Future<void> _open(Offset global) async {
    if (!widget.enabled || widget.entries.isEmpty) return;
    final selected = await showTuiMenu<T>(
      context,
      at: global,
      entries: widget.entries,
    );
    if (selected != null) widget.onSelected?.call(selected);
  }

  @override
  Widget build(BuildContext context) {
    // Desktop secondary click; touch long-press. Avoid stealing primary taps.
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => true,
      _ => false,
    };

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (d) => _lastGlobal = d.globalPosition,
      onLongPress: () {
        final at = _lastGlobal;
        if (at != null) _open(at);
      },
      onSecondaryTapUp: desktop ? (d) => _open(d.globalPosition) : null,
      child: widget.child,
    );
  }
}

/// Theme helper — apply Termul look to any Material [PopupMenuItem] host.
PopupMenuThemeData tuiPopupMenuTheme(TermulPalette p) => PopupMenuThemeData(
  color: p.panel,
  surfaceTintColor: Colors.transparent,
  shadowColor: Colors.transparent,
  elevation: 0,
  textStyle: TextStyle(
    fontFamily: TermulFonts.mono,
    fontSize: 12,
    color: p.text,
  ),
  labelTextStyle: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) {
      return TextStyle(
        fontFamily: TermulFonts.mono,
        fontSize: 12,
        color: p.dim,
      );
    }
    return TextStyle(fontFamily: TermulFonts.mono, fontSize: 12, color: p.text);
  }),
  shape: RoundedRectangleBorder(side: BorderSide(color: p.border)),
);
