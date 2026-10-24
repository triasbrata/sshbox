import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _android = MethodChannel('sshbox/share');
const _keys = MethodChannel('sshbox/keys');
bool _listening = false;

/// MainActivity's calls on `sshbox/keys`, for whichever of [SaveChord] and
/// [RichChords] holds a claim.
void _listen() {
  if (_listening) return;
  _listening = true;
  _keys.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'save':
        SaveChord._save();
      case 'rich':
        RichChords._run(call.arguments as String);
    }
  });
}

/// Claims by owner, and what native was last told about whether there are
/// any: told again only when that answer changes.
class _Claims<T> {
  _Claims(this.method);

  final String method;
  final owners = <Object, T>{};
  bool told = false;

  void want(Object owner, T? run) {
    owners.remove(owner);
    if (run != null) owners[owner] = run;
    final any = owners.isNotEmpty;
    if (any == told || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _listen();
    told = any;
    _android.invokeMethod<void>(method, any).catchError((Object _) {
      // An engine with no MainActivity behind it; nothing to tell.
    });
  }

  /// The newest claim's.
  T? get last => owners.isEmpty ? null : owners.values.last;

  void reset() {
    owners.clear();
    told = false;
  }
}

void _resetChannel() {
  _listening = false;
  _keys.setMethodCallHandler(null);
}

/// Ctrl+S from a hardware keyboard on Android, for the file editor.
///
/// Android gives a key to the input method before the app, and a Ctrl+S
/// that reached Flutter never came out as the chord the editor's own key
/// handler saves on. So MainActivity takes Ctrl+S before the input method,
/// consumes it and calls `save` on the `sshbox/keys` channel; [want] decides
/// when it may: only while an editor page holds the focus and has said so
/// here. Anywhere else, a terminal above all, the key goes the way it always
/// went.
abstract final class SaveChord {
  static final _claims = _Claims<VoidCallback>('saveChord');

  /// [owner] wants Ctrl+S, saving with [save], or no longer does (null).
  /// Several editors may each hold a claim; the newest is the one saved, and
  /// native is told only when the answer to "does any?" changes.
  static void want(Object owner, VoidCallback? save) =>
      _claims.want(owner, save);

  static void _save() => _claims.last?.call();

  @visibleForTesting
  static void reset() {
    _claims.reset();
    _resetChannel();
  }
}

/// Markdown Rich text's Ctrl+B, I, E and K and Shift+arrows from a hardware
/// keyboard on Android, which Gboard takes for itself before the app as it
/// does Ctrl+S: MainActivity takes them first while Rich text has said here
/// that it holds the focus, and hands over the chord's name — `bold`,
/// `italic`, `code`, `link`, or `select:<left|right|up|down>`, with `:word`
/// when Ctrl was down too.
abstract final class RichChords {
  static final _claims = _Claims<ValueChanged<String>>('richChords');

  /// [owner] wants the chords, running them with [run], or no longer does.
  static void want(Object owner, ValueChanged<String>? run) =>
      _claims.want(owner, run);

  static void _run(String chord) => _claims.last?.call(chord);

  @visibleForTesting
  static void reset() {
    _claims.reset();
    _resetChannel();
  }
}
