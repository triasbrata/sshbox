import 'package:flutter/foundation.dart';

/// The terminal a file browser is attached to, and what it may do to it.
///
/// Bundled rather than passed down as loose callbacks because the browser also
/// needs somewhere to keep the "follow" setting. A drawer is torn down every
/// time it closes, so state held inside the page would forget the toggle the
/// moment it went away; owning this in the terminal page fixes that without
/// another pair of parameters.
class TerminalLink extends ChangeNotifier {
  TerminalLink({required this.typePath, required this._changeDirectory});

  /// Puts a path at the prompt, ready to be built into a command. Runs
  /// nothing.
  final void Function(String path) typePath;

  final void Function(String path) _changeDirectory;

  /// The folder this link last sent the shell to. Kept here rather than in
  /// the page for the same reason [follow] is: the drawer forgets.
  ///
  /// ponytail: what was sent, not where the shell is. A `cd` typed by hand,
  /// or a fresh shell after a reconnect, goes unseen, and following back to
  /// this folder then types nothing until another folder is tapped. The
  /// shell's real cwd, read off the host, would close that.
  String? _sentTo;

  /// Sends the shell to a directory.
  void changeDirectory(String path) {
    _sentTo = path;
    _changeDirectory(path);
  }

  /// Sends the shell to [path] when [follow] is on, unless it was sent there
  /// last: tapping a folder open and then shut again is two taps on one
  /// place, and a second `cd` would only be noise at the prompt.
  void followTo(String path) {
    if (_follow && path != _sentTo) changeDirectory(path);
  }

  bool _follow = false;

  /// Whether tapping a folder in the tree, or hanging the tree from one,
  /// should take the shell there too.
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
