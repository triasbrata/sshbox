import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/chat/picture_draft.dart';

TextEditingValue _at(String text, [int? caret]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret ?? text.length),
);

ChatPicture _pic(String name) => ChatPicture(path: '/x/$name', name: name);

void main() {
  test('a picture goes in at the caret as the next number Claude will give, '
      'set off by spaces', () {
    final draft = PictureDraft();
    var value = draft.add(_at('compare with', 7), _pic('a.png'), 3);
    expect(value.text, 'compare [Image #3]  with');
    expect(value.selection.baseOffset, 'compare [Image #3] '.length);
    value = draft.add(value, _pic('b.png'), 3);
    expect(value.text, 'compare [Image #3] [Image #4]  with');
    expect([for (final p in draft.pictures) p.name], ['a.png', 'b.png']);
    expect([for (final p in draft.pictures) p.number], [3, 4]);
  });

  test('removing a card takes its token out and numbers the rest again', () {
    final draft = PictureDraft();
    var value = draft.add(_at(''), _pic('a.png'), 1);
    value = draft.add(value, _pic('b.png'), 1);
    value = TextEditingValue(
      text: '${value.text}see both',
      selection: TextSelection.collapsed(offset: value.text.length + 8),
    );
    expect(value.text, '[Image #1] [Image #2] see both');

    value = draft.remove(value, draft.pictures.first, 1);
    expect(value.text, '[Image #1] see both');
    expect(value.selection.baseOffset, value.text.length);
    expect(draft.pictures.single.name, 'b.png');
    expect(draft.pictures.single.number, 1);
  });

  test('deleting a token takes its card away; a token with no picture is '
      'text', () {
    final draft = PictureDraft();
    var value = draft.add(_at('x'), _pic('a.png'), 1);
    value = draft.add(value, _pic('b.png'), 1);
    expect(value.text, 'x [Image #1] [Image #2] ');

    // Backspaced away, the first token.
    value = draft.sync(_at('x  [Image #2] [Image #9] '), 1);
    expect(draft.pictures.single.name, 'b.png');
    expect(value.text, 'x  [Image #1] [Image #9] ');
  });

  test('moved before another, a token takes the lower number', () {
    final draft = PictureDraft();
    var value = draft.add(_at(''), _pic('a.png'), 1);
    value = draft.add(value, _pic('b.png'), 1);
    value = draft.sync(_at('[Image #2] then [Image #1]', 0), 1);
    expect(value.text, '[Image #1] then [Image #2]');
    expect([for (final p in draft.pictures) p.name], ['b.png', 'a.png']);
  });
}
