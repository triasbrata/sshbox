/// A Markdown file as blocks that are exact pieces of its source, for editing
/// it rendered without rewriting what was not touched.
///
/// The file is always the concatenation of its blocks' [MdBlock.raw], so a
/// block nobody edits goes back byte for byte: its list marker, its emphasis
/// style, its spacing and whatever the editor cannot show are all just bytes
/// carried along. Only a paragraph, an ATX heading and a plain list item whose
/// inline content is text, bold, italic, code and inline links can be edited;
/// every other block is [MdBlockKind.opaque], drawn but never changed.
///
/// What a block says is taken from the markdown package itself, the parser the
/// app renders with, and the source is then aligned against that, character by
/// character. Where the two cannot be aligned exactly, the block is opaque:
/// nothing is edited that might not mean what it shows.
library;

import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;

enum MdBlockKind { gap, paragraph, heading, listItem, opaque }

/// Why a block is not editable, for the hint that sends the reader to Source.
enum MdOpaque {
  frontMatter('front matter'),
  fence('code block'),
  indentedCode('indented block'),
  html('HTML block'),
  quote('quote'),
  rule('rule'),
  table('table'),
  setext('heading'),
  reference('link reference'),
  footnote('footnote'),
  nestedList('nested list'),
  task('task list item'),
  inline('block');

  const MdOpaque(this.label);

  /// What the block is, in the words of the hint.
  final String label;
}

/// How a run of text is marked up.
@immutable
class MdStyle {
  const MdStyle({
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.link,
  });

  static const plain = MdStyle();

  final bool bold;
  final bool italic;
  final bool code;
  final MdLink? link;

  MdStyle copyWith({bool? bold, bool? italic, bool? code, MdLink? link}) =>
      MdStyle(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        code: code ?? this.code,
        link: link ?? this.link,
      );

  MdStyle withoutLink() => MdStyle(bold: bold, italic: italic, code: code);

  @override
  bool operator ==(Object other) =>
      other is MdStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code &&
      other.link == link;

  @override
  int get hashCode => Object.hash(bold, italic, code, link);

  @override
  String toString() =>
      '${bold ? 'B' : ''}${italic ? 'I' : ''}${code ? 'C' : ''}'
      '${link == null ? '' : 'L(${link!.href})'}';
}

/// An inline link. [raw] is its `(destination "title")` as written, kept so a
/// link the user did not change goes back as it was; it plays no part in
/// equality.
@immutable
class MdLink {
  const MdLink(this.href, {this.title, this.raw});

  final String href;
  final String? title;
  final String? raw;

  /// The `(…)` that follows the link text.
  String get target {
    if (raw != null) return raw!;
    final dest = RegExp(r'[\s()<>]').hasMatch(href) ? '<$href>' : href;
    final t = title;
    return t == null ? '($dest)' : '($dest "${t.replaceAll('"', r'\"')}")';
  }

  @override
  bool operator ==(Object other) =>
      other is MdLink && other.href == href && other.title == title;

  @override
  int get hashCode => Object.hash(href, title);
}

/// Which delimiters a block writes bold and italic with.
typedef MdDelims = ({String strong, String em});

const MdDelims _stars = (strong: '**', em: '*');
const MdDelims _underscores = (strong: '__', em: '_');

/// The text of an editable block as it reads, and where each character of it
/// is in the block's source.
class MdInline {
  MdInline(this.text, this.styles, this.from, this.to, this.delims);

  /// What the reader sees, soft line breaks as `\n`.
  final String text;

  /// One per character of [text].
  final List<MdStyle> styles;

  /// Where each character of [text] starts and ends in [MdBlock.raw]: an
  /// escaped `\*` is two source characters for one shown, a soft break the
  /// line break and the indent after it.
  final List<int> from;
  final List<int> to;

  /// The delimiters this block already uses, or null where it uses none.
  final MdDelims? delims;
}

class MdBlock {
  MdBlock._({
    required this.kind,
    required this.shape,
    required this.raw,
    this.why,
    this.prefix = '',
    this.suffix = '',
    this.eol = '',
    this.inline,
  });

  /// What the block is to the editor: [MdBlockKind.opaque] for anything it
  /// cannot edit.
  final MdBlockKind kind;

  /// What the block is in the file, whether or not it can be edited.
  final MdBlockKind shape;

  /// The block's exact source, line breaks included.
  final String raw;

  final MdOpaque? why;

  /// The markup before the content: a heading's `## `, a list item's `- `.
  final String prefix;

  /// A heading's closing `#`s, after one space.
  final String suffix;

  /// The block's own last line break, or nothing at the end of the file.
  final String eol;

  final MdInline? inline;

  bool get editable => inline != null;

  /// An editable paragraph with nothing in it yet, which has no source of its
  /// own until something is typed: Markdown has no empty paragraph.
  factory MdBlock.emptyParagraph({String eol = '\n'}) => MdBlock._(
    kind: MdBlockKind.paragraph,
    shape: MdBlockKind.paragraph,
    raw: '',
    eol: eol,
    inline: MdInline('', const [], const [], const [], null),
  );

  /// A list item's marker with the item's number one on: `3.` → `4.`.
  String get nextPrefix {
    final m = RegExp(r'^(\s*)(\d+)([.)].*)$').firstMatch(prefix);
    if (m == null) return prefix;
    return '${m[1]}${int.parse(m[2]!) + 1}${m[3]}';
  }

  @override
  String toString() => '$kind${why == null ? '' : '(${why!.name})'}: $raw';
}

// ---------------------------------------------------------------------------
// Splitting

final _atx = RegExp(r'^ {0,3}#{1,6}(?:[ \t]|$)');
final _atxPrefix = RegExp(r'^( {0,3}#{1,6})([ \t]+|$)');
final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final _quote = RegExp(r'^ {0,3}>');
final _rule = RegExp(
  r'^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$',
);
final _bulletStart = RegExp(r'^[ \t]*[-*+][ \t]+\S');
final _orderedStart = RegExp(r'^[ \t]*\d{1,9}[.)][ \t]+\S');
final _emptyItem = RegExp(r'^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]*$');
final _orderedOne = RegExp(r'^ {0,3}1[.)][ \t]+\S');
final _listItem = RegExp(
  r'^( {0,3})([-*+]|\d{1,9}[.)])(?:([ \t]{1,4})(\S.*)|[ \t]*)$',
);
final _task = RegExp(r'^\[[ xX]\](?:[ \t]|$)');
final _indented = RegExp(r'^(?: {4}| {0,3}\t)');
final _setext = RegExp(r'^ {0,3}(?:=+|-+)[ \t]*$');
final _tableDelim = RegExp(
  r'^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$',
);
final _reference = RegExp(r'^ {0,3}\[(?:[^\]\\]|\\.)+\]:');
final _footnote = RegExp(r'^ {0,3}\[\^');
final _htmlStart = RegExp(
  r'^ {0,3}<(?:[A-Za-z][A-Za-z0-9-]*(?:[\s/>]|$)|/[A-Za-z]|!--|\?|![A-Za-z]|!\[CDATA\[)',
);
final _htmlRaw = RegExp(
  r'^ {0,3}<(script|pre|style|textarea)(?:[\s>]|$)',
  caseSensitive: false,
);
const _htmlBlockTags = {
  'address', 'article', 'aside', 'base', 'basefont', 'blockquote', 'body', //
  'caption', 'center', 'col', 'colgroup', 'dd', 'details', 'dialog', 'dir',
  'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form',
  'frame', 'frameset', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header',
  'hr', 'html', 'iframe', 'legend', 'li', 'link', 'main', 'menu', 'menuitem',
  'nav', 'noframes', 'ol', 'optgroup', 'option', 'p', 'param', 'search',
  'section', 'summary', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead',
  'title', 'tr', 'track', 'ul',
};

bool _blank(String line) => line.trim().isEmpty;

String _body(String line) =>
    line.endsWith('\n') ? line.substring(0, line.length - 1) : line;

/// Whether an HTML block starting on [line] may cut a paragraph short, as
/// CommonMark's first six kinds may.
bool _htmlInterrupts(String line) {
  if (!_htmlStart.hasMatch(line)) return false;
  if (_htmlRaw.hasMatch(line)) return true;
  final rest = line.trimLeft().substring(1);
  if (rest.startsWith('!') || rest.startsWith('?')) return true;
  final name = RegExp(r'^/?([A-Za-z][A-Za-z0-9-]*)').firstMatch(rest)?[1];
  return name != null && _htmlBlockTags.contains(name.toLowerCase());
}

/// Whether [line] starts a block of its own rather than going on with a
/// paragraph or a list item.
///
/// In a list, an empty item starts one too, as the next item; after a
/// paragraph it is a lazy line.
bool _startsBlock(String line, {required bool inList}) =>
    _atx.hasMatch(line) ||
    _fence.hasMatch(line) ||
    _quote.hasMatch(line) ||
    _rule.hasMatch(line) ||
    _bulletStart.hasMatch(line) ||
    (inList ? _orderedStart : _orderedOne).hasMatch(line) ||
    (inList && _emptyItem.hasMatch(line)) ||
    _htmlInterrupts(line);

/// [text] as its blocks. With [inline] off, editable blocks are not checked
/// against the parser, which is all [MdDoc.consistent] needs to know.
List<MdBlock> splitMarkdown(String text, {bool inline = true}) {
  final lines = <String>[];
  for (var i = 0; i < text.length;) {
    final j = text.indexOf('\n', i);
    if (j < 0) {
      lines.add(text.substring(i));
      break;
    }
    lines.add(text.substring(i, j + 1));
    i = j + 1;
  }
  String line(int k) => _body(lines[k]);
  String rawOf(int from, int to) => lines.sublist(from, to).join();

  final blocks = <MdBlock>[];
  MdBlockKind? lastShape() {
    for (final b in blocks.reversed) {
      if (b.shape != MdBlockKind.gap) {
        return b.why == MdOpaque.nestedList ? MdBlockKind.listItem : b.shape;
      }
    }
    return null;
  }

  void opaque(MdOpaque why, int from, int to) => blocks.add(
    MdBlock._(
      kind: MdBlockKind.opaque,
      shape: MdBlockKind.opaque,
      raw: rawOf(from, to),
      why: why,
    ),
  );

  void editable(
    MdBlockKind shape,
    int from,
    int to,
    String prefix, {
    String suffix = '',
  }) {
    final raw = rawOf(from, to);
    final eol = raw.endsWith('\n') ? '\n' : '';
    final content = raw.substring(
      prefix.length,
      raw.length - eol.length - suffix.length,
    );
    final parsed = inline
        ? _inlineOf(content, prefix.length, shape == MdBlockKind.heading)
        : null;
    blocks.add(
      MdBlock._(
        kind: parsed == null && inline ? MdBlockKind.opaque : shape,
        shape: shape,
        raw: raw,
        why: parsed == null && inline ? MdOpaque.inline : null,
        prefix: prefix,
        suffix: suffix,
        eol: eol,
        inline: parsed,
      ),
    );
  }

  var k = 0;
  if (lines.isNotEmpty && line(0) == '---') {
    for (var e = 1; e < lines.length; e++) {
      if (line(e) == '---' || line(e) == '...') {
        opaque(MdOpaque.frontMatter, 0, e + 1);
        k = e + 1;
        break;
      }
    }
  }

  while (k < lines.length) {
    final l = line(k);
    final start = k;

    if (_blank(l)) {
      while (k < lines.length && _blank(line(k))) {
        k++;
      }
      blocks.add(
        MdBlock._(
          kind: MdBlockKind.gap,
          shape: MdBlockKind.gap,
          raw: rawOf(start, k),
        ),
      );
      continue;
    }

    final fence = _fence.firstMatch(l);
    if (fence != null && !(fence[1]![0] == '`' && fence[2]!.contains('`'))) {
      final marker = fence[1]!;
      final close = RegExp(
        '^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
      );
      k++;
      while (k < lines.length && !close.hasMatch(line(k))) {
        k++;
      }
      opaque(MdOpaque.fence, start, k < lines.length ? k + 1 : k);
      if (k < lines.length) k++;
      continue;
    }

    if (_indented.hasMatch(l)) {
      while (k < lines.length && !_blank(line(k))) {
        k++;
      }
      opaque(MdOpaque.indentedCode, start, k);
      continue;
    }

    final atx = _atxPrefix.firstMatch(l);
    if (atx != null) {
      k++;
      final prefix = atx[0]!;
      final rest = l.substring(prefix.length);
      if (RegExp(r'^#+[ \t]*$').hasMatch(rest)) {
        opaque(MdOpaque.setext, start, k);
        continue;
      }
      var suffix = '';
      final close = RegExp(r'[ \t]+#+[ \t]*$').firstMatch(rest);
      if (close != null) {
        // One space stays with the closing #s; any before it reads as the
        // content's own trailing space, which is how it is typed.
        final hashes = rest.indexOf('#', close.start);
        suffix = rest.substring(hashes - 1);
      }
      editable(MdBlockKind.heading, start, k, prefix, suffix: suffix);
      continue;
    }

    if (_quote.hasMatch(l)) {
      k++;
      while (k < lines.length &&
          !_blank(line(k)) &&
          (_quote.hasMatch(line(k)) || !_startsBlock(line(k), inList: false))) {
        k++;
      }
      opaque(MdOpaque.quote, start, k);
      continue;
    }

    if (_rule.hasMatch(l)) {
      k++;
      opaque(MdOpaque.rule, start, k);
      continue;
    }

    if (_htmlStart.hasMatch(l)) {
      final trimmed = l.trimLeft();
      final raw = _htmlRaw.firstMatch(l)?[1];
      final end = raw != null
          ? RegExp('</$raw>', caseSensitive: false)
          : trimmed.startsWith('<!--')
          ? RegExp('-->')
          : trimmed.startsWith('<?')
          ? RegExp(r'\?>')
          : trimmed.startsWith('<![CDATA[')
          ? RegExp(r'\]\]>')
          : trimmed.startsWith('<!')
          ? RegExp('>')
          : null;
      if (end != null) {
        while (k < lines.length && !end.hasMatch(line(k))) {
          k++;
        }
        if (k < lines.length) k++;
      } else {
        while (k < lines.length && !_blank(line(k))) {
          k++;
        }
      }
      opaque(MdOpaque.html, start, k);
      continue;
    }

    final item = _listItem.firstMatch(l);
    if (item != null) {
      k++;
      final content = item[4];
      if (content != null) {
        while (k < lines.length &&
            !_blank(line(k)) &&
            !_startsBlock(line(k), inList: true)) {
          k++;
        }
      }
      final nested = item[1]!.isNotEmpty && lastShape() == MdBlockKind.listItem;
      if (nested) {
        opaque(MdOpaque.nestedList, start, k);
      } else if (content != null && _task.hasMatch(content)) {
        opaque(MdOpaque.task, start, k);
      } else {
        final prefix = content == null ? l : '${item[1]}${item[2]}${item[3]}';
        editable(MdBlockKind.listItem, start, k, prefix);
      }
      continue;
    }

    if (_reference.hasMatch(l) || _footnote.hasMatch(l)) {
      final why = _footnote.hasMatch(l)
          ? MdOpaque.footnote
          : MdOpaque.reference;
      while (k < lines.length && !_blank(line(k))) {
        k++;
      }
      opaque(why, start, k);
      continue;
    }

    // A paragraph, unless what follows its first line makes it a table or a
    // heading underlined.
    MdOpaque? why = l.startsWith(RegExp(r'[ \t]')) ? MdOpaque.inline : null;
    k++;
    while (k < lines.length && !_blank(line(k))) {
      final next = line(k);
      if (why != MdOpaque.table &&
          _tableDelim.hasMatch(next) &&
          next.contains('|') &&
          line(k - 1).contains('|')) {
        why = MdOpaque.table;
      } else if (why != MdOpaque.table && _setext.hasMatch(next)) {
        k++;
        why = MdOpaque.setext;
        break;
      } else if (_startsBlock(next, inList: false)) {
        break;
      }
      k++;
    }
    if (why != null) {
      opaque(why, start, k);
    } else {
      editable(MdBlockKind.paragraph, start, k, '');
    }
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// Inline content against the parser

final _mdDocument = md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
);

bool _punct(String ch) =>
    ch.length == 1 && r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~'''.contains(ch);

bool _space(String ch) => ch == ' ' || ch == '\t';

/// [content], which starts [base] characters into its block, as it reads, or
/// null where the source cannot be aligned with what the parser makes of it.
MdInline? _inlineOf(String content, int base, bool heading) {
  var end = content.length;
  while (end > 0 && _space(content[end - 1])) {
    end--;
  }
  final c = content.substring(0, end);
  if (heading && c.contains('\n')) return null;
  final w = _Walk(c, base);
  final List<md.Node> nodes;
  try {
    nodes = _mdDocument.parseInline(c);
  } catch (_) {
    return null;
  }
  if (!w.nodes(nodes, MdStyle.plain) || w.p != c.length) return null;
  // Spaces at the very end, which the parser drops, are shown so that a word
  // can be typed after one.
  for (var i = end; i < content.length; i++) {
    w.emit(content[i], MdStyle.plain, base + i, base + i + 1);
  }
  return MdInline(
    w.text.toString(),
    w.styles,
    w.from,
    w.to,
    w.strong == null && w.em == null
        ? null
        : (
            strong: w.strong ?? (w.em == '_' ? '__' : '**'),
            em: w.em ?? (w.strong == '__' ? '_' : '*'),
          ),
  );
}

class _Walk {
  _Walk(this.c, this.base);

  final String c;
  final int base;
  int p = 0;
  final text = StringBuffer();
  final styles = <MdStyle>[];
  final from = <int>[];
  final to = <int>[];
  String? strong;
  String? em;

  void emit(String ch, MdStyle style, int start, int end) {
    text.write(ch);
    styles.add(style);
    from.add(start);
    to.add(end);
  }

  bool nodes(List<md.Node> list, MdStyle style) {
    for (final node in list) {
      if (!(node is md.Text
          ? textNode(node.text, style)
          : element(node, style))) {
        return false;
      }
    }
    return true;
  }

  bool textNode(String t, MdStyle style) {
    for (var i = 0; i < t.length; i++) {
      final ch = t[i];
      if (ch == '\n') {
        // A soft break: spaces before it, which the parser may drop, shown;
        // the break and the next line's indent one character.
        var q = p;
        while (q < c.length && _space(c[q])) {
          q++;
        }
        if (q >= c.length || c[q] != '\n') return false;
        for (var s = p; s < q; s++) {
          emit(c[s], style, base + s, base + s + 1);
        }
        final start = q;
        p = q + 1;
        while (p < c.length && _space(c[p])) {
          p++;
        }
        while (i + 1 < t.length && _space(t[i + 1])) {
          i++;
        }
        emit('\n', style, base + start, base + p);
        continue;
      }
      if (p >= c.length) return false;
      if (c[p] == '\\' && p + 1 < c.length && c[p + 1] == ch && _punct(ch)) {
        emit(ch, style, base + p, base + p + 2);
        p += 2;
        continue;
      }
      if (c[p] != ch) return false;
      // A bracket or a tag the parser left as text is still one a reader may
      // take for markup, or one a whole-document parse would resolve.
      if (ch == '[' || ch == ']') return false;
      if (ch == '<' &&
          p + 1 < c.length &&
          RegExp(r'[A-Za-z/!?]').hasMatch(c[p + 1])) {
        return false;
      }
      emit(ch, style, base + p, base + p + 1);
      p++;
    }
    return true;
  }

  bool element(md.Node node, MdStyle style) {
    if (node is! md.Element) return false;
    switch (node.tag) {
      case 'strong':
        if (p + 2 > c.length) return false;
        final d = c.substring(p, p + 2);
        if (d != '**' && d != '__') return false;
        strong ??= d;
        p += 2;
        if (!nodes(node.children ?? const [], style.copyWith(bold: true))) {
          return false;
        }
        if (!c.startsWith(d, p)) return false;
        p += 2;
        return true;
      case 'em':
        if (p >= c.length) return false;
        final d = c[p];
        if (d != '*' && d != '_') return false;
        em ??= d;
        p++;
        if (!nodes(node.children ?? const [], style.copyWith(italic: true))) {
          return false;
        }
        if (!c.startsWith(d, p)) return false;
        p++;
        return true;
      case 'code':
        var k = 0;
        while (p + k < c.length && c[p + k] == '`') {
          k++;
        }
        if (k == 0) return false;
        final fence = '`' * k;
        var close = p + k;
        while (true) {
          close = c.indexOf(fence, close);
          if (close < 0) return false;
          final longer = close + k < c.length && c[close + k] == '`';
          if (!longer) break;
          while (close < c.length && c[close] == '`') {
            close++;
          }
        }
        final inner = c.substring(p + k, close);
        if (inner.contains('\n')) return false;
        var shown = inner;
        var off = 0;
        if (inner.length >= 2 &&
            inner.startsWith(' ') &&
            inner.endsWith(' ') &&
            inner.trim().isNotEmpty) {
          shown = inner.substring(1, inner.length - 1);
          off = 1;
        }
        if (shown != node.textContent) return false;
        final s = style.copyWith(code: true);
        for (var i = 0; i < shown.length; i++) {
          final at = base + p + k + off + i;
          emit(shown[i], s, at, at + 1);
        }
        p = close + k;
        return true;
      case 'a':
        if (p >= c.length || c[p] != '[') return false;
        final href = node.attributes['href'];
        if (href == null) return false;
        final title = node.attributes['title'];
        p++;
        final linkStart = text.length;
        if (!nodes(
          node.children ?? const [],
          style.copyWith(link: MdLink(href, title: title)),
        )) {
          return false;
        }
        if (!c.startsWith('](', p)) return false;
        final open = p + 1;
        final close = _closingParen(c, open);
        if (close < 0) return false;
        final link = MdLink(
          href,
          title: title,
          raw: c.substring(open, close + 1),
        );
        for (var i = linkStart; i < styles.length; i++) {
          styles[i] = styles[i].copyWith(link: link);
        }
        p = close + 1;
        return true;
    }
    return false;
  }
}

/// Where the `(` at [open] closes, past a `<…>` destination and a quoted
/// title, or -1.
int _closingParen(String c, int open) {
  var depth = 0;
  String? quote;
  var angle = false;
  for (var i = open; i < c.length; i++) {
    final ch = c[i];
    if (ch == '\\') {
      i++;
      continue;
    }
    if (quote != null) {
      if (ch == quote) quote = null;
      continue;
    }
    if (angle) {
      if (ch == '>') angle = false;
      continue;
    }
    if (ch == '<' && i == open + 1) {
      angle = true;
    } else if ((ch == '"' || ch == "'") && i > open + 1 && _space(c[i - 1])) {
      quote = ch;
    } else if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Editing

/// A change to one editable block's text: [text] and [styles] are what it
/// should read afterwards. Where it came from typing, the span [a, b) of the
/// old text was replaced by [ins] in [insStyle]: that is what lets the change
/// go into the source where it was made, touching nothing else.
class MdEdit {
  const MdEdit(
    this.text,
    this.styles, {
    this.a,
    this.b,
    this.ins = '',
    this.insStyle,
  });

  final String text;
  final List<MdStyle> styles;
  final int? a;
  final int? b;
  final String ins;
  final MdStyle? insStyle;
}

/// An HTML entity, which Markdown reads as the character it names.
final _entity = RegExp(r'^&#?[A-Za-z0-9]+;');

bool _sameInline(MdInline x, String text, List<MdStyle> styles) =>
    x.text == text && listEquals(x.styles, styles);

/// [ins] as source. [level] 1 escapes what usually means markup; 2 escapes
/// every punctuation mark, for a line start or a run of them the first could
/// not keep plain.
String _escape(String ins, int level, String indent) {
  final out = StringBuffer();
  for (var i = 0; i < ins.length; i++) {
    final ch = ins[i];
    if (ch == '\n') {
      out.write('\n$indent');
    } else if (level >= 2 ? _punct(ch) : r'\*_`[]<~'.contains(ch)) {
      out.write('\\$ch');
    } else if (ch == '&' && _entity.hasMatch(ins.substring(i))) {
      out.write(r'\&');
    } else {
      out.write(ch);
    }
  }
  return out.toString();
}

/// Bold and italic taken off spaces at the edges of a marked run, where
/// Markdown cannot put a delimiter.
List<MdStyle> _normalized(String text, List<MdStyle> styles) {
  final out = List.of(styles);
  bool isSpace(int i) => text[i] == ' ' || text[i] == '\t' || text[i] == '\n';
  for (final bold in [true, false]) {
    bool on(int i) => bold ? out[i].bold : out[i].italic;
    MdStyle off(MdStyle s) => bold
        ? MdStyle(bold: false, italic: s.italic, code: s.code, link: s.link)
        : MdStyle(bold: s.bold, italic: false, code: s.code, link: s.link);
    var i = 0;
    while (i < out.length) {
      if (!on(i)) {
        i++;
        continue;
      }
      var j = i;
      while (j < out.length && on(j)) {
        j++;
      }
      var s = i;
      while (s < j && isSpace(s) && !out[s].code) {
        out[s] = off(out[s]);
        s++;
      }
      var e = j - 1;
      while (e >= s && isSpace(e) && !out[e].code) {
        out[e] = off(out[e]);
        e--;
      }
      i = j;
    }
  }
  return out;
}

String? _serializeInline(
  String text,
  List<MdStyle> styles,
  MdDelims delims,
  String indent, {
  required bool lineStarts,
}) {
  final out = StringBuffer();
  final stack = <Object>[];
  var atLineStart = lineStarts;

  void close(Object mark) {
    if (mark is MdLink) {
      out.write(']${mark.target}');
    } else {
      out.write(mark == #bold ? delims.strong : delims.em);
    }
  }

  var i = 0;
  while (i < text.length) {
    var j = i + 1;
    while (j < text.length && styles[j] == styles[i]) {
      j++;
    }
    final style = styles[i];
    final segment = text.substring(i, j);
    final want = <Object>[
      ?style.link,
      if (style.bold) #bold,
      if (style.italic) #italic,
    ];
    // Marks still wanted stay open, in whatever order they were opened, so
    // `*a **b** c*` is written as it reads rather than closed and reopened.
    var keep = 0;
    while (keep < stack.length && want.contains(stack[keep])) {
      keep++;
    }
    while (stack.length > keep) {
      close(stack.removeLast());
    }
    for (final mark in want.where((m) => !stack.contains(m))) {
      out.write(
        mark is MdLink ? '[' : (mark == #bold ? delims.strong : delims.em),
      );
      stack.add(mark);
      atLineStart = false;
    }
    if (style.code) {
      if (segment.contains('\n')) return null;
      var longest = 0;
      for (final m in RegExp('`+').allMatches(segment)) {
        if (m[0]!.length > longest) longest = m[0]!.length;
      }
      final fence = '`' * (longest + 1);
      final pad =
          segment.startsWith('`') ||
              segment.endsWith('`') ||
              (segment.startsWith(' ') &&
                  segment.endsWith(' ') &&
                  segment.trim().isNotEmpty)
          ? ' '
          : '';
      out.write('$fence$pad$segment$pad$fence');
      atLineStart = false;
    } else {
      for (var k = 0; k < segment.length; k++) {
        final ch = segment[k];
        if (ch == '\n') {
          out.write('\n$indent');
          atLineStart = true;
          continue;
        }
        if (atLineStart) {
          final rest = segment.substring(k);
          final number = RegExp(r'^\d{1,9}([.)])').firstMatch(rest);
          if (number != null) {
            out.write('${rest.substring(0, number.end - 1)}\\${number[1]}');
            k += number.end - 1;
            atLineStart = false;
            continue;
          }
          if ('#>+-=|'.contains(ch)) {
            out.write('\\$ch');
            atLineStart = false;
            continue;
          }
        }
        // An entity's `&` is seen with what follows it, not alone.
        final entity = ch == '&' && _entity.hasMatch(segment.substring(k));
        out.write(entity ? r'\&' : _escape(ch, 1, indent));
        atLineStart = false;
      }
    }
    i = j;
  }
  while (stack.isNotEmpty) {
    close(stack.removeLast());
  }
  return out.toString();
}

/// [old] with [edit] made, or null where it cannot be written as Markdown of
/// the same kind. [accept] has the last word on each candidate, for what only
/// the whole document can tell.
///
/// Typing goes into the source where it was made, escaped as little as will
/// do. Only when that does not read back as intended — and for a change of
/// marks, which has no one place to go — is the block written afresh, in the
/// delimiters it already uses. Either way the result is parsed again and must
/// read exactly as asked.
MdBlock? editBlock(
  MdBlock old,
  MdEdit edit, {
  bool Function(MdBlock block)? accept,
  MdDelims? delims,
}) {
  final m = old.inline;
  if (m == null) return null;
  bool ok(MdBlock b) => accept == null || accept(b);
  final indent = old.shape == MdBlockKind.listItem
      ? ' ' * old.prefix.length
      : '';
  final heading = old.shape == MdBlockKind.heading;
  if (heading && edit.text.contains('\n')) return null;

  if (edit.text.isEmpty && old.shape == MdBlockKind.paragraph) {
    final b = MdBlock.emptyParagraph(eol: old.eol.isEmpty ? '\n' : old.eol);
    return ok(b) ? b : null;
  }

  MdBlock? reread(String raw, String text, List<MdStyle> styles) {
    final again = splitMarkdown(raw);
    if (again.length != 1) return null;
    final b = again.single;
    if (b.kind != old.shape || b.inline == null) return null;
    if (!_sameInline(b.inline!, text, styles)) return null;
    return ok(b) ? b : null;
  }

  final a = edit.a;
  final b = edit.b ?? a;
  if (a != null && b != null && m.text.isNotEmpty) {
    final natural = b > a
        ? m.styles[a]
        : a > 0
        ? m.styles[a - 1]
        : m.styles[0];
    final style = edit.insStyle ?? natural;
    final codeOk =
        !style.code || (!edit.ins.contains('`') && !edit.ins.contains('\n'));
    if (edit.ins.isEmpty || (style == natural && codeOk)) {
      final start = b > a ? m.from[a] : (a > 0 ? m.to[a - 1] : m.from[0]);
      final end = b > a ? m.to[b - 1] : start;
      for (final level in style.code ? [0] : [1, 2]) {
        final ins = style.code ? edit.ins : _escape(edit.ins, level, indent);
        final raw = old.raw.replaceRange(start, end, ins);
        final got = reread(raw, edit.text, edit.styles);
        if (got != null) return got;
      }
    }
  }

  final styles = _normalized(edit.text, edit.styles);
  final tries = <MdDelims>{?delims ?? m.delims, _stars, _underscores};
  for (final d in tries) {
    final content = _serializeInline(
      edit.text,
      styles,
      d,
      indent,
      lineStarts: old.shape == MdBlockKind.paragraph,
    );
    if (content == null) return null;
    var prefix = old.prefix;
    if (content.isNotEmpty &&
        prefix.isNotEmpty &&
        !prefix.endsWith(' ') &&
        !prefix.endsWith('\t')) {
      prefix = '$prefix ';
    }
    final raw = '$prefix$content${old.suffix}${old.eol}';
    final got = reread(raw, edit.text, styles);
    if (got != null) return got;
  }
  return null;
}

/// A change made to the document, and where the caret goes after it.
class MdChange {
  const MdChange(this.doc, this.block, this.caret);

  final MdDoc doc;

  /// The block the caret is in afterwards, and how far into its text.
  final int block;
  final int caret;
}

class MdDoc {
  MdDoc(this.blocks);

  factory MdDoc.parse(String text) => MdDoc(splitMarkdown(text));

  final List<MdBlock> blocks;

  String get text => blocks.map((b) => b.raw).join();

  /// The delimiters the document already writes bold and italic with, for a
  /// block that has used neither yet.
  late final MdDelims delims =
      blocks.map((b) => b.inline?.delims).nonNulls.firstOrNull ?? _stars;

  /// Whether [blocks], as edited, are what their own text splits into: an
  /// edit that would change how a block beside it reads is not made.
  static bool consistent(List<MdBlock> blocks) {
    List<(MdBlockKind, String)> canon(Iterable<MdBlock> list) {
      final out = <(MdBlockKind, String)>[];
      for (final b in list) {
        if (b.raw.isEmpty) continue;
        final shape = b.why == MdOpaque.inline ? b.shape : b.kind;
        if (shape == MdBlockKind.gap &&
            out.isNotEmpty &&
            out.last.$1 == MdBlockKind.gap) {
          out.last = (MdBlockKind.gap, out.last.$2 + b.raw);
        } else {
          out.add((shape, b.raw));
        }
      }
      return out;
    }

    final text = blocks.map((b) => b.raw).join();
    return listEquals(canon(splitMarkdown(text, inline: false)), canon(blocks));
  }

  List<MdBlock> _with(int i, List<MdBlock> replacement, {int count = 1}) =>
      List.of(blocks)..replaceRange(i, i + count, replacement);

  /// Block [i] edited, or null when the edit cannot be written faithfully.
  MdChange? edit(int i, MdEdit e, {required int caret}) {
    final edited = editBlock(
      blocks[i],
      e,
      delims: delims,
      accept: (b) => consistent(_with(i, [b])),
    );
    if (edited == null) return null;
    return MdChange(MdDoc(_with(i, [edited])), i, caret);
  }

  /// Block [i] cut in two at [at] of its text, as Enter does: a paragraph
  /// and a heading go on in a new paragraph, a list item in a new item.
  MdChange? split(int i, int at) {
    final old = blocks[i];
    final m = old.inline;
    if (m == null) return null;
    final eol = old.eol.isEmpty ? '\n' : old.eol;
    final leftText = m.text.substring(0, at);
    // A new block cannot start with a space Markdown would keep.
    var from = at;
    while (from < m.text.length && _space(m.text[from])) {
      from++;
    }
    final rightText = m.text.substring(from);
    final rightStyles = m.styles.sublist(from);
    final item = old.shape == MdBlockKind.listItem;

    final MdBlock left;
    if (at == m.text.length) {
      left = MdBlock._(
        kind: old.kind,
        shape: old.shape,
        raw: old.raw.isEmpty
            ? ''
            : old.raw.substring(0, old.raw.length - old.eol.length) + eol,
        prefix: old.prefix,
        suffix: old.suffix,
        eol: eol,
        inline: m,
      );
    } else {
      final l = editBlock(
        MdBlock._(
          kind: old.kind,
          shape: old.shape,
          raw: old.raw.substring(0, old.raw.length - old.eol.length) + eol,
          prefix: old.prefix,
          suffix: old.suffix,
          eol: eol,
          inline: m,
        ),
        MdEdit(leftText, m.styles.sublist(0, at), a: at, b: m.text.length),
        delims: delims,
      );
      if (l == null) return null;
      left = l;
    }

    final template = MdBlock._(
      kind: item ? MdBlockKind.listItem : MdBlockKind.paragraph,
      shape: item ? MdBlockKind.listItem : MdBlockKind.paragraph,
      raw: item ? '${old.nextPrefix}${old.eol}' : '',
      prefix: item ? old.nextPrefix : '',
      eol: old.eol,
      inline: MdInline('', const [], const [], const [], m.delims),
    );
    MdBlock? right;
    if (rightText.isEmpty) {
      right = item
          ? MdBlock._(
              kind: MdBlockKind.listItem,
              shape: MdBlockKind.listItem,
              raw: '${old.nextPrefix.trimRight()}${old.eol}',
              prefix: old.nextPrefix.trimRight(),
              eol: old.eol,
              inline: template.inline,
            )
          : MdBlock.emptyParagraph(eol: old.eol);
    } else {
      right = editBlock(
        template,
        MdEdit(rightText, rightStyles),
        delims: delims,
      );
    }
    if (right == null) return null;
    final gap = MdBlock._(
      kind: MdBlockKind.gap,
      shape: MdBlockKind.gap,
      raw: '\n',
    );
    final replacement = [left, if (!item) gap, right];
    final next = _with(i, replacement);
    if (!consistent(next)) return null;
    return MdChange(MdDoc(next), i + replacement.length - 1, 0);
  }

  /// Block [i] joined onto the editable block before it, as Backspace at its
  /// start does. Null where there is none to join, a gap aside.
  MdChange? mergeBack(int i) {
    final cur = blocks[i];
    final m = cur.inline;
    if (m == null) return null;
    var p = i - 1;
    while (p >= 0 && blocks[p].kind == MdBlockKind.gap) {
      p--;
    }
    if (p < 0 || !blocks[p].editable) {
      if (m.text.isNotEmpty || i == 0) return null;
      // An empty block with nothing editable before it just goes.
      final from = blocks[i - 1].kind == MdBlockKind.gap ? i - 1 : i;
      final next = List.of(blocks)..removeRange(from, i + 1);
      if (!consistent(next)) return null;
      return MdChange(MdDoc(next), -1, 0);
    }
    final prev = blocks[p];
    final pm = prev.inline!;
    final caret = pm.text.length;
    final MdBlock? joined;
    if (m.text.isEmpty) {
      joined = prev;
    } else if (pm.text.isEmpty) {
      joined = editBlock(prev, MdEdit(m.text, m.styles), delims: delims);
    } else {
      // The two sources simply put together first, which keeps both as they
      // were whenever their marks do not run into each other.
      final contentEnd = prev.raw.length - prev.eol.length - prev.suffix.length;
      final curContent = cur.raw.substring(
        cur.prefix.length,
        cur.raw.length - cur.eol.length - cur.suffix.length,
      );
      final raw = prev.raw.replaceRange(contentEnd, contentEnd, curContent);
      final text = pm.text + m.text;
      final styles = [...pm.styles, ...m.styles];
      final again = splitMarkdown(raw);
      if (again.length == 1 &&
          again.single.kind == prev.shape &&
          again.single.inline != null &&
          _sameInline(again.single.inline!, text, styles)) {
        joined = again.single;
      } else {
        joined = editBlock(prev, MdEdit(text, styles), delims: delims);
      }
    }
    if (joined == null) return null;
    final next = List.of(blocks)..replaceRange(p, i + 1, [joined]);
    if (!consistent(next)) return null;
    return MdChange(MdDoc(next), p, caret);
  }
}
