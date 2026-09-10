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

  /// Sends the shell to a directory.
  final void Function(String path) changeDirectory;

  bool _follow = false;

  /// Whether browsing into a directory should take the shell there too.
  ///
  /// Off until asked for, and deliberately so: this types a command into a
  /// live shell, and a shell is not always sitting at a prompt. With something
  /// running in it — an editor, a build, anything reading stdin — a `cd`
  /// arrives as input to that program instead, which is a mess the user did
  /// not ask for by tapping a folder.
  bool get follow => _follow;

  set follow(bool value) {
    if (_follow == value) return;
    _follow = value;
    notifyListeners();
  }
}
