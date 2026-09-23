import 'package:flutter/material.dart';

import 'tui.dart';

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
class TabGroupView extends StatelessWidget {
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

  /// termul's split view: its grip, its 48dp floor, its accent outline, and
  /// only the outlined pane holding focus.
  @override
  Widget build(BuildContext context) => TuiSplitView(
    axis: group.stacked ? TuiSplitAxis.vertical : TuiSplitAxis.horizontal,
    focusedId: focused,
    onFocus: onFocus,
    onWeightsChanged: group.weights.addAll,
    panes: [
      for (final id in group.ids)
        TuiSplitPane(id: id, weight: group.weightOf(id), child: pages[id]!),
    ],
  );
}
