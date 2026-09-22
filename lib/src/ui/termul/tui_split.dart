// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_split.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

/// Side-by-side vs stacked pane layout.
enum TuiSplitAxis { horizontal, vertical }

/// One pane in [TuiSplitView] — host supplies [child] and optional [weight].
class TuiSplitPane {
  const TuiSplitPane({required this.id, required this.child, this.weight = 1});

  final String id;
  final Widget child;

  /// Relative share of the room. Default `1` = even with siblings.
  final double weight;
}

/// Tabs shown together as panes — ids only; pages live in the host map.
class TuiTabGroup {
  TuiTabGroup(
    this.ids, {
    this.stacked = false,
    this.focused,
    Map<String, double>? weights,
  }) : weights = weights ?? {};

  /// Pane order: left→right or top→bottom.
  final List<String> ids;

  /// `true` = stacked (vertical); `false` = side by side.
  bool stacked;

  final Map<String, double> weights;
  String? focused;

  double weightOf(String id) => weights[id] ?? 1;

  TuiSplitAxis get axis =>
      stacked ? TuiSplitAxis.vertical : TuiSplitAxis.horizontal;
}

/// Optional controller for join / leave / flip — host may own state instead.
class TuiTabGroups extends ChangeNotifier {
  final List<TuiTabGroup> _all = [];

  List<TuiTabGroup> get all => List.unmodifiable(_all);

  TuiTabGroup? of(String id) =>
      _all.where((g) => g.ids.contains(id)).firstOrNull;

  void join(String id, String target) {
    if (id == target) return;
    _leave(id);
    final group = of(target);
    if (group == null) {
      _all.add(TuiTabGroup([target, id]));
    } else {
      group.ids.add(id);
    }
    notifyListeners();
  }

  void leave(String id) {
    _leave(id);
    notifyListeners();
  }

  void _leave(String id) {
    final group = of(id);
    if (group == null) return;
    group.ids.remove(id);
    group.weights.remove(id);
    if (group.ids.length < 2) _all.remove(group);
  }

  void ungroup(TuiTabGroup group) {
    _all.remove(group);
    notifyListeners();
  }

  void flip(TuiTabGroup group) {
    group.stacked = !group.stacked;
    notifyListeners();
  }

  void keepOnly(List<String> ids) {
    for (final group in _all) {
      group.ids.removeWhere((id) => !ids.contains(id));
      if (!group.ids.contains(group.focused)) group.focused = null;
    }
    _all.removeWhere((g) => g.ids.length < 2);
  }

  /// Strip slots: lone tab ids, or a [TuiTabGroup] at its first pane's place.
  List<Object> slots(List<String> ids) {
    final out = <Object>[];
    for (final id in ids) {
      final group = of(id);
      if (group == null) {
        out.add(id);
      } else if (group.ids.first == id) {
        out.add(group);
      }
    }
    return out;
  }
}

/// Resizable pane grid — focused pane outlined (tmux-style).
///
/// Presentation only: host owns [panes] weights; drag emits [onWeightsChanged].
class TuiSplitView extends StatefulWidget {
  const TuiSplitView({
    super.key,
    required this.panes,
    required this.axis,
    this.focusedId,
    this.onFocus,
    this.onWeightsChanged,
    this.gripThickness = 8,
    this.minPaneSize = 48,
  });

  final List<TuiSplitPane> panes;
  final TuiSplitAxis axis;
  final String? focusedId;
  final ValueChanged<String>? onFocus;

  /// Fired after a grip drag with the new weight map (by pane id).
  final ValueChanged<Map<String, double>>? onWeightsChanged;

  final double gripThickness;
  final double minPaneSize;

  /// Convenience from a [TuiTabGroup] + page map.
  factory TuiSplitView.fromGroup({
    Key? key,
    required TuiTabGroup group,
    required Map<String, Widget> pages,
    String? focusedId,
    ValueChanged<String>? onFocus,
    ValueChanged<Map<String, double>>? onWeightsChanged,
  }) {
    return TuiSplitView(
      key: key,
      axis: group.axis,
      focusedId: focusedId ?? group.focused,
      onFocus: onFocus,
      onWeightsChanged: onWeightsChanged,
      panes: [
        for (final id in group.ids)
          TuiSplitPane(id: id, weight: group.weightOf(id), child: pages[id]!),
      ],
    );
  }

  @override
  State<TuiSplitView> createState() => _TuiSplitViewState();
}

class _TuiSplitViewState extends State<TuiSplitView> {
  late final Map<String, double> _weights = {
    for (final p in widget.panes) p.id: p.weight,
  };

  @override
  void didUpdateWidget(TuiSplitView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.panes.map((p) => p.id).toSet();
    _weights.removeWhere((id, _) => !ids.contains(id));
    for (final p in widget.panes) {
      _weights.putIfAbsent(p.id, () => p.weight);
      // Sync when host replaces weights from outside (unless mid-drag — host
      // should pass updated panes after onWeightsChanged).
      if (oldWidget.panes.every((o) => o.id != p.id || o.weight == p.weight)) {
        continue;
      }
      _weights[p.id] = p.weight;
    }
  }

  double _w(String id) => _weights[id] ?? 1;

  void _drag(int index, double delta, double room) {
    final before = widget.panes[index - 1].id;
    final after = widget.panes[index].id;
    final a = _w(before);
    final b = _w(after);
    final total = widget.panes.map((p) => _w(p.id)).reduce((x, y) => x + y);
    final floor = math.min(total * widget.minPaneSize / room, (a + b) / 2);
    final moved = (delta / room * total).clamp(floor - a, b - floor);
    setState(() {
      _weights[before] = a + moved;
      _weights[after] = b - moved;
    });
    widget.onWeightsChanged?.call(Map.unmodifiable(_weights));
  }

  @override
  Widget build(BuildContext context) {
    final stacked = widget.axis == TuiSplitAxis.vertical;
    final panes = widget.panes;
    if (panes.isEmpty) return const SizedBox.shrink();
    if (panes.length == 1) {
      return _FocusPane(
        focused: panes.first.id == widget.focusedId,
        onFocus: () => widget.onFocus?.call(panes.first.id),
        child: panes.first.child,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final room =
            (stacked ? constraints.maxHeight : constraints.maxWidth) -
            widget.gripThickness * (panes.length - 1);
        return Flex(
          direction: stacked ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, pane) in panes.indexed) ...[
              if (index > 0)
                _Grip(
                  stacked: stacked,
                  thickness: widget.gripThickness,
                  onDrag: (delta) => _drag(index, delta, room),
                ),
              Expanded(
                key: ValueKey(pane.id),
                flex: math.max(1, (_w(pane.id) * 1000).round()),
                child: _FocusPane(
                  focused: pane.id == widget.focusedId,
                  onFocus: () => widget.onFocus?.call(pane.id),
                  child: pane.child,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _FocusPane extends StatefulWidget {
  const _FocusPane({
    required this.focused,
    required this.onFocus,
    required this.child,
  });

  final bool focused;
  final VoidCallback onFocus;
  final Widget child;

  @override
  State<_FocusPane> createState() => _FocusPaneState();
}

class _FocusPaneState extends State<_FocusPane> {
  final _scope = FocusScopeNode(debugLabel: 'Tui split pane');

  @override
  void didUpdateWidget(_FocusPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.focused || oldWidget.focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.focused) return;
      _scope.requestFocus();
      FocusNode? node = _scope.focusedChild;
      while (node is FocusScopeNode) {
        node = node.focusedChild;
      }
      node?.consumeKeyboardToken();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Listener(
      onPointerDown: (_) => widget.onFocus(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: !widget.focused,
            child: FocusScope(node: _scope, child: widget.child),
          ),
          if (widget.focused)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: p.accent.withValues(alpha: 0.75)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Grip extends StatelessWidget {
  const _Grip({
    required this.stacked,
    required this.thickness,
    required this.onDrag,
  });

  final bool stacked;
  final double thickness;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return MouseRegion(
      cursor: stacked
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: stacked ? null : (d) => onDrag(d.delta.dx),
        onVerticalDragUpdate: stacked ? (d) => onDrag(d.delta.dy) : null,
        child: ColoredBox(
          color: p.surface,
          child: SizedBox(
            width: stacked ? null : thickness,
            height: stacked ? thickness : null,
            child: Center(
              child: Container(
                width: stacked ? 28 : 2,
                height: stacked ? 2 : 28,
                color: p.border,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Strip chip for a tab group: outline around layout toggle + member chips.
///
/// Sharp Termul outline (no pill radius). Pass each tab's chip as [children].
class TuiTabGroupChip extends StatelessWidget {
  const TuiTabGroupChip({
    super.key,
    required this.children,
    this.stacked = false,
    this.active = false,
    this.onActivate,
    this.onFlip,
    this.onUngroup,
  });

  final List<Widget> children;
  final bool stacked;
  final bool active;
  final VoidCallback? onActivate;
  final VoidCallback? onFlip;
  final VoidCallback? onUngroup;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        border: Border.all(
          color: active ? p.accent.withValues(alpha: 0.75) : p.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GroupLead(
            stacked: stacked,
            onActivate: onActivate,
            onFlip: onFlip,
            onUngroup: onUngroup,
          ),
          ...children,
        ],
      ),
    );
  }
}

class _GroupLead extends StatelessWidget {
  const _GroupLead({
    required this.stacked,
    required this.onActivate,
    required this.onFlip,
    required this.onUngroup,
  });

  final bool stacked;
  final VoidCallback? onActivate;
  final VoidCallback? onFlip;
  final VoidCallback? onUngroup;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return PopupMenuButton<String>(
      tooltip: 'Tab group',
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'activate':
            onActivate?.call();
          case 'flip':
            onFlip?.call();
          case 'ungroup':
            onUngroup?.call();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'activate',
          enabled: onActivate != null,
          child: const Text('Focus group'),
        ),
        PopupMenuItem(
          value: 'flip',
          enabled: onFlip != null,
          child: Text(stacked ? 'Side by side' : 'Stacked'),
        ),
        PopupMenuItem(
          value: 'ungroup',
          enabled: onUngroup != null,
          child: const Text('Ungroup'),
        ),
      ],
      child: InkWell(
        onTap: onActivate,
        child: SizedBox(
          width: 32,
          height: 28,
          child: Center(
            child: Text(
              stacked ? '☰' : '▥',
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 13,
                color: p.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small tab label for use inside [TuiTabGroupChip] or a plain strip.
class TuiTabChip extends StatelessWidget {
  const TuiTabChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.onClose,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        color: selected ? p.panel : Colors.transparent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TuiText(
              label,
              size: 12,
              bold: selected,
              tone: selected ? TuiTextTone.accent : TuiTextTone.muted,
            ),
            if (onClose != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onClose,
                child: Text(
                  '×',
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 12,
                    color: p.dim,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
