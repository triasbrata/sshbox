import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ctrl+S from a hardware keyboard on Android, for the file editor.
///
/// Android gives a key to the input method before the app, and Gboard takes
/// Ctrl+S as typing: it commits an "s" and Flutter never hears a key. So
/// MainActivity looks at Ctrl+S before the input method and hands it to
/// Flutter's own key handling instead — but only while an editor page holds
/// the focus and has said so here. Anywhere else, a terminal above all, the
/// key goes the way it always went, ^S included.
abstract final class SaveChord {
  static const _android = MethodChannel('sshbox/share');
  static final _owners = <Object>{};
  static bool _told = false;

  /// [owner] wants Ctrl+S, or no longer does. Several editors may each hold
  /// a claim; native is told only when the answer to "does any?" changes.
  static void want(Object owner, bool on) {
    if (on) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    final any = _owners.isNotEmpty;
    if (any == _told || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _told = any;
    _android.invokeMethod<void>('saveChord', any).catchError((Object _) {
      // An engine with no MainActivity behind it; nothing to tell.
    });
  }

  @visibleForTesting
  static void reset() {
    _owners.clear();
    _told = false;
  }
}
