import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  static const _android = MethodChannel('sshbox/share');
  static const _keys = MethodChannel('sshbox/keys');
  static final _owners = <Object, VoidCallback>{};
  static bool _told = false;
  static bool _listening = false;

  /// [owner] wants Ctrl+S, saving with [save], or no longer does (null).
  /// Several editors may each hold a claim; the newest is the one saved, and
  /// native is told only when the answer to "does any?" changes.
  static void want(Object owner, VoidCallback? save) {
    _owners.remove(owner);
    if (save != null) _owners[owner] = save;
    final any = _owners.isNotEmpty;
    if (any == _told || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    if (!_listening) {
      _listening = true;
      _keys.setMethodCallHandler(_onCall);
    }
    _told = any;
    _android.invokeMethod<void>('saveChord', any).catchError((Object _) {
      // An engine with no MainActivity behind it; nothing to tell.
    });
  }

  static Future<void> _onCall(MethodCall call) async {
    if (call.method == 'save' && _owners.isNotEmpty) _owners.values.last();
  }

  @visibleForTesting
  static void reset() {
    _owners.clear();
    _told = false;
    _listening = false;
    _keys.setMethodCallHandler(null);
  }
}
