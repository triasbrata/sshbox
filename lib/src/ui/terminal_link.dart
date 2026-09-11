import 'package:flutter/foundation.dart';

/// The terminal a file browser is attached to, and what it may do to it.
///
/// Bundled rather than passed down as loose callbacks because the browser also
/// needs somewhere to keep the "follow" setting. A drawer is torn down every
/// time it closes, so state held inside the page would forget the toggle the
/// moment it went away; owning this in the terminal page fixes that without
/// another pair of parameters.
class TerminalLink extends ChangeNotifier {
  TerminalLink({required this.typePath, required this.changeDirectory});

  /// Puts a path at the prompt, ready to be built into a command. Runs
  /// nothing.
  final void Function(String path) typePath;

  /// Sends the shell to a directory, if it is sitting at its prompt and not
  /// there already. Both are the terminal's to check: only it can ask the
  /// host.
  final void Function(String path) changeDirectory;

  /// Sends the shell to [path] when [follow] is on.
  void followTo(String path) {
    if (_follow) changeDirectory(path);
  }

  bool _follow = false;

  /// Whether tapping a folder in the tree, or hanging the tree from one,
  /// should take the shell there too.
  ///
  /// Off until asked for, and deliberately so: this types a command into a
  /// live shell on every tap. The terminal refuses while a program has it —
  /// an editor, a build, anything reading stdin, where a `cd` would arrive as
  /// input to that program — but a shell that wanders off with every folder
  /// tapped is still something to choose rather than find out about.
  bool get follow => _follow;

  set follow(bool value) {
    if (_follow == value) return;
    _follow = value;
    notifyListeners();
  }
}
