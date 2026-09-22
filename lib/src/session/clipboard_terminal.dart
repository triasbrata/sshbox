import 'dart:convert';

import 'package:xterm2/xterm.dart';

/// The most a program may put on the clipboard in one go, decoded: 1 MB.
/// Anything bigger is dropped whole rather than cut short.
const maxClipboardBytes = 1 << 20;

/// A terminal that lets a program on the host copy to the clipboard, and
/// never read from it.
///
/// A program copies with OSC 52, `ESC ] 52 ; <target> ; <base64> BEL`: Claude
/// Code's `/copy`, its own mouse selection, vim's and tmux's yanks all send
/// it, since over SSH there is no other way to reach the clipboard of the
/// machine the terminal runs on. xterm2 parses it, but reads no escape
/// sequence longer than 8 KB, so anything past about 6 KB of text — a long
/// reply taken with `/copy` — was dropped without a word. It is taken out of
/// the stream here instead, before xterm2's parser sees it, up to
/// [maxClipboardBytes], and handed to [onClipboardStore] as text — whoever
/// shows the terminal decides what that does, see `_PaneView`.
///
/// Asking for the clipboard, `ESC ] 52 ; c ; ? BEL`, is never answered: the
/// answer would go to the host, and so would a password copied a minute
/// before on the machine itself. xterm2's own view answers it for a focused
/// terminal, given the chance; [onClipboardQuery] set here takes the chance
/// away, and the query itself is dropped on the way in.
///
/// The target is not told apart: `c`, `p` and `s` all go to the one
/// clipboard Flutter can write, as xterm2 reads them; a target naming only
/// cut buffers is dropped.
///
/// Inside tmux, Claude Code sends each copy twice: plain, and again in tmux's
/// passthrough, `ESC P tmux; ESC ESC ] 52 … ESC \`, for a terminal outside
/// tmux. A tmux tab gets both, control mode handing on what a pane writes as
/// it wrote it, so the wrapped one is taken out and dropped: one copy, one
/// toast.
class ClipboardTerminal extends Terminal {
  ClipboardTerminal({super.maxLines, super.inputHandler})
    : super(onClipboardQuery: _refuse);

  static String? _refuse(String _) => null;

  static const _start = '\x1b]52;';

  /// The target, its `;` and the data: four characters for every three bytes.
  static const _maxEncoded = 16 + (maxClipboardBytes + 2) ~/ 3 * 4;

  static final _base64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

  /// What the last write ended on that may begin an OSC 52, or the ESC that
  /// may end one: held until the next write says.
  String _held = '';

  /// The OSC 52 being read, after its `ESC ] 52 ;`; null outside one.
  StringBuffer? _osc;

  /// Past [_maxEncoded]: read to its end and dropped.
  bool _oscTooBig = false;

  /// Inside tmux's passthrough: read to its end and dropped.
  bool _oscWrapped = false;

  @override
  void write(String data) {
    final text = _held + data;
    _held = '';
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      if (_osc != null) {
        i = _readOsc(text, i);
        continue;
      }
      final at = text.indexOf(_start, i);
      if (at < 0) {
        final keep = _partial(text, i);
        out.write(text.substring(i, text.length - keep));
        _held = text.substring(text.length - keep);
        break;
      }
      // tmux's passthrough doubles every ESC it carries, so this one is the
      // same copy again, wrapped for a terminal outside tmux. Its ESC goes
      // with it, or xterm2 would read the ESC ESC as the end of the DCS and
      // what follows as an OSC 52 of its own.
      final wrapped = at > i && text.codeUnitAt(at - 1) == 0x1b;
      out.write(text.substring(i, wrapped ? at - 1 : at));
      _osc = StringBuffer();
      _oscTooBig = false;
      _oscWrapped = wrapped;
      i = at + _start.length;
    }
    if (out.isNotEmpty) super.write(out.toString());
  }

  /// How much of the end of [text], past [from], could be the start of an
  /// OSC 52 the next write finishes.
  static int _partial(String text, int from) {
    for (var k = _start.length - 1; k > 0; k--) {
      if (text.length - k >= from && text.endsWith(_start.substring(0, k))) {
        return k;
      }
    }
    return 0;
  }

  /// Reads the OSC 52 on from [from], ending it the ways xterm2 ends any OSC,
  /// and says where the text after it starts. What ends it by starting
  /// something else — an ESC not followed by `\`, a C1 control — is left to
  /// be read as that.
  int _readOsc(String text, int from) {
    final osc = _osc!;
    for (var j = from; j < text.length; j++) {
      final char = text.codeUnitAt(j);
      if (char == 0x07 || char == 0x9c) {
        _finish();
        return j + 1;
      }
      if (char == 0x1b) {
        if (j + 1 == text.length) {
          _held = '\x1b';
          return text.length;
        }
        if (text.codeUnitAt(j + 1) == 0x5c) {
          _finish();
          return j + 2;
        }
        _osc = null;
        return j;
      }
      if (char == 0x18 || char == 0x1a) {
        _osc = null;
        return j + 1;
      }
      if (char >= 0x80 && char <= 0x9f) {
        _osc = null;
        return j;
      }
      // Other C0 controls are skipped inside an OSC, as xterm2 skips them: a
      // base64 wrapped at 76 columns still reads.
      if (char < 0x20 || _oscTooBig) continue;
      if (osc.length >= _maxEncoded) {
        _oscTooBig = true;
        osc.clear();
        continue;
      }
      osc.writeCharCode(char);
    }
    return text.length;
  }

  void _finish() {
    final payload = _osc.toString();
    final drop = _oscTooBig || _oscWrapped;
    _osc = null;
    if (drop) return;
    final semicolon = payload.indexOf(';');
    if (semicolon < 0) return;
    final target = payload.substring(0, semicolon);
    if (target.isNotEmpty && !target.contains(RegExp('[cps]'))) return;
    final copied = decodeClipboard(payload.substring(semicolon + 1));
    if (copied != null) onClipboardStore?.call('c', copied);
  }

  /// [data] as the text it encodes, or null for anything that is not plain
  /// base64 of UTF-8 within [maxClipboardBytes]: a query (`?`), nothing at
  /// all, the URL-safe alphabet, a missing pad, bytes that are not UTF-8.
  static String? decodeClipboard(String data) {
    if (!_base64.hasMatch(data)) return null;
    try {
      final bytes = base64.decode(data);
      if (bytes.length > maxClipboardBytes) return null;
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}
