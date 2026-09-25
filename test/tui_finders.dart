import 'package:flutter/material.dart' show AnimatedContainer, TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/tui.dart';

/// The termul button whose label is [label] as written, not in the capitals
/// it is drawn in: for a test that reads the button itself, as whether it is
/// enabled. A tap finds it by `find.bySemanticsLabel(label)`, as a screen
/// reader and the e2e flows do.
Finder findTuiButton(String label) => find.byWidgetPredicate(
  (widget) => widget is TuiButton && widget.label == label,
  description: 'TuiButton "$label"',
);

/// The termul switch labelled [label].
Finder findTuiSwitch(String label) => find.byWidgetPredicate(
  (widget) => widget is TuiSwitch && widget.label == label,
  description: 'TuiSwitch "$label"',
);

/// The text field inside the termul field captioned [label].
Finder findTuiField(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is TuiField && widget.label == label,
    description: 'TuiField "$label"',
  ),
  matching: find.byType(TextField),
);

/// What a tap on the termul switch labelled [label] lands on: its track,
/// the only part of it that toggles.
Finder findTuiSwitchTrack(String label) => find.descendant(
  of: findTuiSwitch(label),
  matching: find.byType(AnimatedContainer),
);
