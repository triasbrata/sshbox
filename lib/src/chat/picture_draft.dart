import 'package:flutter/services.dart';

import 'claude_chat.dart';

/// The pictures a message being written carries, each one a card above the
/// box and an `[Image #N]` in its text where it goes.
///
/// The two are kept as one: removing a card takes its token out of the text,
/// deleting a token takes its card away, and the numbers always run from
/// [ClaudeChat.nextPicture] in the order the tokens stand in the text — the
/// order they are pasted in, which is how Claude numbers them.
class PictureDraft {
  final List<ChatPicture> _pictures = [];

  /// In the order their tokens stand in the text.
  List<ChatPicture> get pictures => List.unmodifiable(_pictures);

  bool get isEmpty => _pictures.isEmpty;

  /// [value] with [picture]'s token put in where the caret is, or over what
  /// is selected.
  TextEditingValue add(TextEditingValue value, ChatPicture picture, int first) {
    final number =
        _pictures.fold(
          first - 1,
          (most, p) => p.number > most ? p.number : most,
        ) +
        1;
    _pictures.add(_numbered(picture, number));
    final text = value.text;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: text.length);
    final before = text.substring(0, selection.start);
    // A space either side, so the token is never run into a word.
    final token =
        '${before.isEmpty || before.endsWith(' ') ? '' : ' '}'
        '[Image #$number] ';
    return sync(
      TextEditingValue(
        text: before + token + text.substring(selection.end),
        selection: TextSelection.collapsed(
          offset: selection.start + token.length,
        ),
      ),
      first,
    );
  }

  /// [value] without [picture]'s token, and the picture gone.
  TextEditingValue remove(
    TextEditingValue value,
    ChatPicture picture,
    int first,
  ) {
    final match = RegExp('${RegExp.escape('[Image #${picture.number}]')} ?')
        .firstMatch(value.text);
    if (match == null) {
      _pictures.removeWhere((p) => p.number == picture.number);
      return sync(value, first);
    }
    final caret = value.selection.baseOffset;
    final cut = match.end - match.start;
    return sync(
      TextEditingValue(
        text: value.text.replaceRange(match.start, match.end, ''),
        selection: TextSelection.collapsed(
          offset: caret <= match.start
              ? caret
              : caret >= match.end
              ? caret - cut
              : match.start,
        ),
      ),
      first,
    );
  }

  /// After the text changed: a picture whose token is gone goes, and the rest
  /// are numbered from [first] in the order their tokens stand, the text
  /// rewritten to match. A token no picture has is the user's own text.
  TextEditingValue sync(TextEditingValue value, int first) {
    final byNumber = {for (final p in _pictures) p.number: p};
    final order = <ChatPicture>[];
    final renumber = <int, int>{};
    for (final match in pictureToken.allMatches(value.text)) {
      final number = int.parse(match[1]!);
      final picture = byNumber.remove(number);
      if (picture == null) continue;
      renumber[match.start] = first + order.length;
      order.add(picture);
    }
    _pictures
      ..clear()
      ..addAll([
        for (final (index, picture) in order.indexed)
          _numbered(picture, first + index),
      ]);
    final at = value.selection.baseOffset;
    var caret = at;
    final text = value.text.replaceAllMapped(pictureToken, (match) {
      final number = renumber[match.start];
      if (number == null) return match[0]!;
      final token = '[Image #$number]';
      if (match.end <= at) caret += token.length - match[0]!.length;
      return token;
    });
    if (text == value.text) return value;
    return TextEditingValue(
      text: text,
      selection: value.selection.isValid
          ? TextSelection.collapsed(offset: caret.clamp(0, text.length))
          : value.selection,
    );
  }

  void clear() => _pictures.clear();

  static ChatPicture _numbered(ChatPicture picture, int number) => ChatPicture(
    path: picture.path,
    bytes: picture.bytes,
    name: picture.name,
    number: number,
  );
}
