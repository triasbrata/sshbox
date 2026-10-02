import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [child]'s selectable text, copied with what a reader expects between its
/// pieces: a newline between blocks (paragraphs, list items, headings, code
/// blocks) and between a table's rows, a tab between a row's cells.
///
/// Flutter joins what a selection covers with nothing at all, so a drag
/// across a table and the paragraph after it pasted as `NameNotealphafirst
/// cell…After`. Put inside a SelectionArea, around the Markdown it covers;
/// a selection inside one paragraph or one cell is one piece and gains no
/// separator.
class SeparatedSelection extends StatefulWidget {
  const SeparatedSelection({super.key, required this.child});

  final Widget child;

  @override
  State<SeparatedSelection> createState() => _SeparatedSelectionState();
}

class _SeparatedSelectionState extends State<SeparatedSelection> {
  final _delegate = _SeparatedDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

/// What a list draws before an item: a bullet, a number, or a task box.
final _marker = RegExp(r'^\s*(?:[•◦▪·*-]|\d+[.)])\s*$');

class _SeparatedDelegate extends StaticSelectionContainerDelegate {
  /// Where [selectable]'s content sits on screen.
  Rect? _where(Selectable selectable) {
    final boxes = selectable.boundingBoxes;
    if (boxes.isEmpty) return null;
    final to = selectable.getTransformTo(null);
    return boxes
        .map((box) => MatrixUtils.transformRect(to, box))
        .reduce((a, b) => a.expandToInclude(b));
  }

  @override
  SelectedContent? getSelectedContent() {
    final buffer = StringBuffer();
    Rect? before;
    var lastText = '';
    var any = false;
    for (final selectable in selectables) {
      final content = selectable.getSelectedContent();
      if (content == null) continue;
      any = true;
      final where = _where(selectable);
      if (before != null && where != null && buffer.isNotEmpty) {
        final text = buffer.toString();
        // Side by side, left to right: the cells of one row. Anything else
        // is the next block, or the next row, below.
        final overlap =
            where.top < before.bottom - 1 && where.bottom > before.top + 1;
        if (overlap && where.left >= before.right - 1) {
          // A list's marker and its item sit side by side too, and are one
          // line, not two cells.
          buffer.write(_marker.hasMatch(lastText) ? ' ' : '\t');
        } else if (!text.endsWith('\n')) {
          buffer.write('\n');
        }
      }
      buffer.write(content.plainText);
      lastText = content.plainText;
      if (where != null) before = where;
    }
    return any ? SelectedContent(plainText: buffer.toString()) : null;
  }
}
