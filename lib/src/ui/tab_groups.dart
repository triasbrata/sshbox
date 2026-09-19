import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tabs shown together, each page in a pane of its own, the way tmux splits
/// a window: see [TabGroupView]. A group keeps only its tabs' ids, so a tab
/// that closes simply leaves it.
class TabGroup {
  TabGroup(this.ids);

  /// The tabs, in pane order: left to right, or top to bottom.
  final List<String> ids;

  /// Top to bottom rather than side by side.
  bool stacked = false;

  /// What each pane has been dragged to. Its share of the room is its weight
  /// over theirs all, and a pane never dragged weighs 1: a tab joining gets
  /// an even share without taking back what the others were given.
  final Map<String, double> weights = {};

  double weightOf(String id) => weights[id] ?? 1;

  /// The pane last focused, which the group's own button goes back to.
  String? focused;

  /// The view's, so it keeps its panes as tabs open or close before it.
  final key = GlobalKey();
}

/// Every tab group on the strip. The groups last as long as the app: tab ids
/// are made afresh by each run, so there is nothing yet to save them by.
class TabGroups extends ChangeNotifier {
  final List<TabGroup> _all = [];

  TabGroup? of(String id) =>
      _all.where((group) => group.ids.contains(id)).firstOrNull;

  /// Puts [id] in a pane beside [target]: at the end of [target]'s group, or
  /// in a new group of the two. A tab in another group leaves that first.
  void join(String id, String target) {
    if (id == target) return;
    _leave(id);
    final group = of(target);
    if (group == null) {
      _all.add(TabGroup([target, id]));
    } else {
      group.ids.add(id);
    }
    notifyListeners();
  }

  /// Takes [id] out of its group, back into a tab of its own.
  void leave(String id) {
    _leave(id);
    notifyListeners();
  }

  /// A group left with one tab is no group.
  void _leave(String id) {
    final group = of(id);
    if (group == null) return;
    group.ids.remove(id);
    group.weights.remove(id);
    if (group.ids.length < 2) _all.remove(group);
  }

  /// Every tab of [group] back into a tab of its own.
  void ungroup(TabGroup group) {
    _all.remove(group);
    notifyListeners();
  }

  /// Side by side becomes stacked, and stacked side by side.
  void flip(TabGroup group) {
    group.stacked = !group.stacked;
    notifyListeners();
  }

  /// Lets go of the tabs no longer open, [ids] being those that are. Quietly:
  /// it runs as the tabs are built.
  void keepOnly(List<String> ids) {
    for (final group in _all) {
      group.ids.removeWhere((id) => !ids.contains(id));
      if (!group.ids.contains(group.focused)) group.focused = null;
    }
    _all.removeWhere((group) => group.ids.length < 2);
  }

  /// The strip's order, [ids], with each group's tabs gathered where its
  /// first pane's tab would be: a tab's id on its own, else its group.
  List<Object> slots(List<String> ids) {
    final slots = <Object>[];
    for (final id in ids) {
      final group = of(id);
      if (group == null) {
        slots.add(id);
      } else if (group.ids.first == id) {
        slots.add(group);
      }
    }
    return slots;
  }
}

/// A group's pages, each in a pane: side by side or stacked, a grip between
/// each two that drags to share the room out anew, and the focused pane
/// outlined, as tmux draws its panes.
///
/// Only the focused pane may hold focus, as only the showing tab may, so no
/// key goes to a pane that is not outlined. Touching a pane focuses it.
class TabGroupView extends StatefulWidget {
  const TabGroupView({
    super.key,
    required this.group,
    required this.pages,
    required this.focused,
    required this.onFocus,
  });

  final TabGroup group;

  /// Every open tab's page, by id; the group shows its own.
  final Map<String, Widget> pages;

  /// The pane that holds the keys: null while the group is not showing.
  final String? focused;

  final void Function(String id) onFocus;

  @override
  State<TabGroupView> createState() => _TabGroupViewState();
}

class _TabGroupViewState extends State<TabGroupView> {
  /// How thick the grip between two panes is.
  static const double _grip = 8;

  /// Moves the grip before pane [index] by [delta], out of [room] to share.
  /// No pane is squeezed under 48dp.
  void _drag(int index, double delta, double room) {
    final group = widget.group;
    final before = group.ids[index - 1];
    final after = group.ids[index];
    final a = group.weightOf(before);
    final b = group.weightOf(after);
    final total = group.ids.map(group.weightOf).reduce((x, y) => x + y);
    final floor = math.min(total * 48 / room, (a + b) / 2);
    final moved = (delta / room * total).clamp(floor - a, b - floor);
    setState(() {
      group.weights[before] = a + moved;
      group.weights[after] = b - moved;
    });
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final stacked = group.stacked;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room =
            (stacked ? constraints.maxHeight : constraints.maxWidth) -
            _grip * (group.ids.length - 1);
        return Flex(
          direction: stacked ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, id) in group.ids.indexed) ...[
              if (index > 0)
                _Grip(
                  stacked: stacked,
                  thickness: _grip,
                  onDrag: (delta) => _drag(index, delta, room),
                ),
              Expanded(
                // By id, so a pane keeps its place in the focus as another
                // leaves from before it.
                key: ValueKey(id),
                flex: math.max(1, (group.weightOf(id) * 1000).round()),
                child: _Pane(
                  focused: id == widget.focused,
                  onFocus: () => widget.onFocus(id),
                  child: widget.pages[id]!,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Pane extends StatefulWidget {
  const _Pane({
    required this.focused,
    required this.onFocus,
    required this.child,
  });

  final bool focused;
  final VoidCallback onFocus;
  final Widget child;

  @override
  State<_Pane> createState() => _PaneState();
}

class _PaneState extends State<_Pane> {
  /// Remembers what in the pane last had focus, for when it is focused again.
  final _scope = FocusScopeNode(debugLabel: 'Tab group pane');

  @override
  void didUpdateWidget(_Pane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.focused || oldWidget.focused) return;
    // Focused from the strip rather than by a touch, typing goes back to
    // where it last was in the pane, without the soft keyboard, as a tab
    // shown again does. After the frame, once the pane may take focus.
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
    final theme = Theme.of(context);
    // A Listener rather than a gesture, so the touch still goes on to the
    // page's own taps, swipes and scrolling.
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
                  // tmux's own pane outline: see TmuxPaneLayout.
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The gutter between two panes, with a grip in it to drag.
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
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: stacked
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: stacked ? null : (d) => onDrag(d.delta.dx),
        onVerticalDragUpdate: stacked ? (d) => onDrag(d.delta.dy) : null,
        child: ColoredBox(
          color: theme.colorScheme.surfaceContainerHighest,
          child: SizedBox(
            width: stacked ? null : thickness,
            height: stacked ? thickness : null,
            child: Center(
              child: Container(
                width: stacked ? 32 : 3,
                height: stacked ? 3 : 32,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
