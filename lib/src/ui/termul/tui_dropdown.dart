// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_dropdown.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// A control's Semantics is its own node (container: true), so its word is
// not merged into whatever is around it: a screen reader, an e2e flow and a
// finder can each reach it by that word.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

/// One row in [TuiDropdown] / [showTuiDropdownMenu].
class TuiDropdownOption<T> {
  const TuiDropdownOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final bool enabled;
}

/// When option count is at or above this, the menu shows a filter field.
const tuiDropdownSearchThreshold = 8;

/// Form dropdown for long lists (jump host, DB type, port-forward host).
///
/// Closed state matches [TuiField]. Opens a sharp panel with optional search
/// and a scrollable list. Prefer [TuiSelect] for a handful of choices.
class TuiDropdown<T> extends StatelessWidget {
  const TuiDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    this.onChanged,
    this.hint = 'Select…',
    this.errorText,
    this.enabled = true,
    this.searchable,
    this.maxMenuHeight = 280,
    this.emptyLabel = 'None',
    this.allowClear = false,
  });

  final String label;
  final List<TuiDropdownOption<T>> options;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final String hint;
  final String? errorText;
  final bool enabled;

  /// `null` = auto when [options.length] ≥ [tuiDropdownSearchThreshold].
  final bool? searchable;
  final double maxMenuHeight;

  /// Shown for a null [value] when [allowClear] is used as a menu row.
  final String emptyLabel;
  final bool allowClear;

  bool get _searchable =>
      searchable ?? options.length >= tuiDropdownSearchThreshold;

  TuiDropdownOption<T>? get _selected {
    if (value == null) return null;
    for (final o in options) {
      if (o.value == value) return o;
    }
    return null;
  }

  Future<void> _open(BuildContext context) async {
    if (!enabled || onChanged == null) return;
    final picked = await showTuiDropdownMenu<T>(
      context,
      anchor: context,
      options: options,
      value: value,
      searchable: _searchable,
      maxHeight: maxMenuHeight,
      allowClear: allowClear,
      emptyLabel: emptyLabel,
    );
    if (picked == _DropdownSentinel.clear) {
      onChanged!(null);
    } else if (picked is T) {
      onChanged!(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final hasError = errorText != null && errorText!.isNotEmpty;
    final selected = _selected;
    final active = enabled && onChanged != null;

    final display = selected?.label ?? hint;
    final displayTone = !active
        ? TuiTextTone.dim
        : selected == null
        ? TuiTextTone.dim
        : TuiTextTone.normal;

    return Semantics(
      container: true,
      button: true,
      enabled: active,
      label: label,
      value: selected?.label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall!.copyWith(
              color: hasError ? p.red : p.accent,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: active ? () => _open(context) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: p.panel,
                  border: Border.all(
                    color: hasError
                        ? p.red
                        : active
                        ? p.border
                        : p.border.withValues(alpha: 0.6),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TuiText(
                            display,
                            size: 13,
                            tone: displayTone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (selected?.subtitle != null)
                            TuiText(
                              selected!.subtitle!,
                              size: 11,
                              tone: TuiTextTone.dim,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    Text(
                      '▾',
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 12,
                        color: active ? p.dim : p.dim.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (hasError)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                errorText!,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 11,
                  color: p.red,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Sentinel returned when the user clears the selection.
enum _DropdownSentinel { clear }

/// Opens a searchable dropdown panel under [anchor] (or at [at]).
///
/// Returns the chosen value, [_DropdownSentinel.clear] when cleared, or
/// `null` if dismissed. Prefer [TuiDropdown] for form use.
Future<Object?> showTuiDropdownMenu<T>(
  BuildContext context, {
  Offset? at,
  BuildContext? anchor,
  required List<TuiDropdownOption<T>> options,
  T? value,
  bool searchable = false,
  double maxHeight = 280,
  double minWidth = 220,
  double maxWidth = 360,
  bool allowClear = false,
  String emptyLabel = 'None',
}) {
  assert(
    at != null || anchor != null,
    'showTuiDropdownMenu needs at or anchor',
  );

  final p = TermulThemeData.of(context).palette;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;

  late final RelativeRect position;
  late final double fieldWidth;
  if (at != null) {
    final local = overlay.globalToLocal(at);
    position = RelativeRect.fromRect(
      local & Size.zero,
      Offset.zero & overlay.size,
    );
    fieldWidth = minWidth;
  } else {
    final box = anchor!.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    // Open below the field face (skip the uppercase label by using full
    // widget — still fine; panel aligns to left edge).
    position = RelativeRect.fromRect(
      Rect.fromLTWH(topLeft.dx, topLeft.dy + size.height + 2, size.width, 0),
      Offset.zero & overlay.size,
    );
    fieldWidth = size.width.clamp(minWidth, maxWidth);
  }

  return Navigator.of(context)
      .push<_DropdownResult>(
        _TuiDropdownRoute(
          position: position,
          width: fieldWidth,
          maxHeight: maxHeight,
          maxWidth: maxWidth,
          barrierFill: Colors.transparent,
          paletteBorder: p.border,
          panel: p.panel,
          child: _DropdownPanel<T>(
            options: options,
            value: value,
            searchable: searchable,
            allowClear: allowClear,
            emptyLabel: emptyLabel,
            maxHeight: maxHeight,
          ),
        ),
      )
      .then((r) => r?.value);
}

class _DropdownResult {
  const _DropdownResult(this.value);
  final Object? value;
}

class _TuiDropdownRoute extends PopupRoute<_DropdownResult> {
  _TuiDropdownRoute({
    required this.position,
    required this.width,
    required this.maxHeight,
    required this.maxWidth,
    required this.barrierFill,
    required this.paletteBorder,
    required this.panel,
    required this.child,
  });

  final RelativeRect position;
  final double width;
  final double maxHeight;
  final double maxWidth;
  final Color barrierFill;
  final Color paletteBorder;
  final Color panel;
  final Widget child;

  @override
  Color? get barrierColor => barrierFill;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss dropdown';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 100);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _DropdownLayout(position, width, maxWidth),
      child: FadeTransition(
        opacity: animation,
        child: Material(
          color: panel,
          elevation: 0,
          shape: RoundedRectangleBorder(side: BorderSide(color: paletteBorder)),
          child: child,
        ),
      ),
    );
  }
}

class _DropdownLayout extends SingleChildLayoutDelegate {
  _DropdownLayout(this.position, this.width, this.maxWidth);

  final RelativeRect position;
  final double width;
  final double maxWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: width,
      maxWidth: width.clamp(0, maxWidth),
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = size.width - position.right - childSize.width;
    // Prefer left-aligned with the field (`position.left`).
    x = position.left;
    if (x + childSize.width > size.width) {
      x = size.width - childSize.width - 8;
    }
    if (x < 8) x = 8;

    var y = position.top;
    if (y + childSize.height > size.height) {
      y = size.height - childSize.height - 8;
    }
    if (y < 8) y = 8;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_DropdownLayout oldDelegate) =>
      position != oldDelegate.position || width != oldDelegate.width;
}

class _DropdownPanel<T> extends StatefulWidget {
  const _DropdownPanel({
    required this.options,
    required this.value,
    required this.searchable,
    required this.allowClear,
    required this.emptyLabel,
    required this.maxHeight,
  });

  final List<TuiDropdownOption<T>> options;
  final T? value;
  final bool searchable;
  final bool allowClear;
  final String emptyLabel;
  final double maxHeight;

  @override
  State<_DropdownPanel<T>> createState() => _DropdownPanelState<T>();
}

class _DropdownPanelState<T> extends State<_DropdownPanel<T>> {
  final _filter = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
    if (widget.searchable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<TuiDropdownOption<T>> get _shown {
    final q = _filter.text.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return [
      for (final o in widget.options)
        if (o.label.toLowerCase().contains(q) ||
            (o.subtitle?.toLowerCase().contains(q) ?? false))
          o,
    ];
  }

  void _pick(Object? value) {
    Navigator.of(context).pop(_DropdownResult(value));
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final shown = _shown;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.searchable)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: TextField(
                controller: _filter,
                focusNode: _focus,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 13,
                  color: p.text,
                ),
                cursorColor: p.accent,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter…',
                  hintStyle: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 13,
                    color: p.dim,
                  ),
                  border: InputBorder.none,
                  prefixText: '/ ',
                  prefixStyle: TextStyle(
                    fontFamily: TermulFonts.mono,
                    color: p.dim,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          if (widget.searchable)
            Divider(height: 1, thickness: 1, color: p.border),
          if (widget.allowClear)
            _Row(
              label: widget.emptyLabel,
              selected: widget.value == null,
              onTap: () => _pick(_DropdownSentinel.clear),
            ),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No matches',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 12,
                  color: p.dim,
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    widget.maxHeight -
                    (widget.searchable ? 48 : 0) -
                    (widget.allowClear ? 40 : 0),
              ),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final o = shown[i];
                  return _Row(
                    label: o.label,
                    subtitle: o.subtitle,
                    selected: o.value == widget.value,
                    enabled: o.enabled,
                    onTap: o.enabled ? () => _pick(o.value) : null,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.label,
    this.subtitle,
    this.selected = false,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final active = widget.enabled && widget.onTap != null;

    return MouseRegion(
      onEnter: active ? (_) => setState(() => _hover = true) : null,
      onExit: active ? (_) => setState(() => _hover = false) : null,
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: widget.selected
              ? p.selection
              : _hover
              ? p.selection.withValues(alpha: 0.5)
              : Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: widget.selected
                    ? Text(
                        '✓',
                        style: TextStyle(
                          fontFamily: TermulFonts.mono,
                          fontSize: 12,
                          color: p.accent,
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 13,
                        color: active ? p.text : p.dim,
                      ),
                    ),
                    if (widget.subtitle != null)
                      Text(
                        widget.subtitle!,
                        style: TextStyle(
                          fontFamily: TermulFonts.mono,
                          fontSize: 11,
                          color: p.dim,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
