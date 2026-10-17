import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'key_bar.dart';
import 'markdown_blocks.dart';
import 'termul/termul_theme.dart';

/// A Markdown file edited as it reads: paragraphs, headings and list items
/// typed into where they are drawn, bold, italic, code and links marked from
/// [MarkdownRichBar] or the usual keys, and every other block drawn as the
/// preview drew it, read-only, behind a lock that offers Source.
///
/// The document lives in [text], which is the editor's own: every change goes
/// out through [onChanged] as the whole new text, and anything that changes
/// [text] from outside — an undo, a reload, an edit in Source — is read back
/// in. That keeps one text, one save and one undo history for both modes.
///
/// Nothing is ever written back but the block being edited, and that only as
/// [editBlock] allows: see markdown_blocks.dart.
class MarkdownRichEditor extends StatefulWidget {
  const MarkdownRichEditor({
    super.key,
    required this.text,
    required this.onChanged,
    required this.styleSheet,
    required this.opaqueBuilder,
    required this.onOpenLink,
    required this.onEditInSource,
    required this.onRefused,
    required this.askLink,
    this.onUndo,
    this.onRedo,
    this.at = 0,
    this.onScroll,
    this.controller,
  });

  final String text;

  /// The document after an edit. [coalesce] is set while the user goes on
  /// typing in the same block, so one undo takes back the run, not a letter.
  final void Function(String text, {required bool coalesce}) onChanged;

  /// The preview's own sheet, so what is typed looks like what was read.
  final MarkdownStyleSheet styleSheet;

  /// Draws a block that cannot be edited here, from its Markdown.
  final Widget Function(BuildContext context, String markdown) opaqueBuilder;

  final void Function(MdLink link) onOpenLink;

  /// Shows the source at 1-based [line], where a read-only block is edited.
  final void Function(int line) onEditInSource;

  /// Says why something typed was not taken.
  final void Function(String message) onRefused;

  /// Asks for a link's address, [current] filled in; null when cancelled and
  /// empty to take the link off.
  final Future<String?> Function(String? current) askLink;

  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  /// Where it was last left, in pixels, as the preview kept it.
  final double at;
  final ValueChanged<double>? onScroll;

  /// For the bar below the page, which acts on the block being typed in.
  final MarkdownRichController? controller;

  /// ponytail: the same ceiling the preview had. Blocks past it are left out
  /// rather than drawn, and never touched, since only a block on screen can
  /// be edited.
  static const limit = 100 * 1024;

  @override
  State<MarkdownRichEditor> createState() => _MarkdownRichEditorState();
}

/// What the formatting bar reads and does, for the block with the caret.
class MarkdownRichController extends ChangeNotifier {
  _MarkdownRichEditorState? _state;

  /// The marks at the caret, or across the selection, in the block being
  /// edited; null while no block has the caret.
  MdStyle? get style => _state?._styleAtCaret();

  void toggleBold() =>
      _state?._toggle((s, on) => s.copyWith(bold: on), (s) => s.bold);
  void toggleItalic() =>
      _state?._toggle((s, on) => s.copyWith(italic: on), (s) => s.italic);
  void toggleCode() =>
      _state?._toggle((s, on) => s.copyWith(code: on), (s) => s.code);
  Future<void> editLink() async => _state?._editLink();

  bool _scheduled = false;
  bool _disposed = false;

  /// Tells the bar, after the frame when the change came during a build: a
  /// read-back from an undo happens while the page builds.
  void _changed() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _Field {
  _Field(MdInline inline)
    : controller = _RichTextController(inline),
      focus = FocusNode();

  final _RichTextController controller;
  final FocusNode focus;
  final key = GlobalKey();

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

class _RichTextController extends TextEditingController {
  _RichTextController(MdInline inline)
    : styles = List.of(inline.styles),
      super(text: inline.text);

  List<MdStyle> styles;

  /// Marks picked with nothing selected, for what is typed next at [_pendingAt].
  MdStyle? pending;
  int _pendingAt = -1;

  late MarkdownStyleSheet sheet;

  void setInline(MdInline inline, {TextSelection? selection}) {
    styles = List.of(inline.styles);
    value = TextEditingValue(
      text: inline.text,
      selection:
          selection ??
          (this.selection.isValid && this.selection.end <= inline.text.length
              ? this.selection
              : TextSelection.collapsed(offset: inline.text.length)),
    );
  }

  MdStyle? get pendingHere =>
      selection.isCollapsed && selection.baseOffset == _pendingAt
      ? pending
      : null;

  /// Redraws after [styles] changed with the text left as it was.
  void restyled() => notifyListeners();

  void setPending(MdStyle style) {
    pending = style;
    _pendingAt = selection.baseOffset;
    notifyListeners();
  }

  TextStyle _look(MdStyle s, TextStyle base) {
    var style = base;
    if (s.code) style = style.merge(sheet.code);
    if (s.link != null) style = style.merge(sheet.a);
    if (s.bold) style = style.copyWith(fontWeight: FontWeight.bold);
    if (s.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    return style;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final children = <TextSpan>[];
    final t = text;
    if (styles.length != t.length) return TextSpan(text: t, style: base);
    var i = 0;
    while (i < t.length) {
      var j = i + 1;
      bool inComposing(int k) =>
          composing.isValid && k >= composing.start && k < composing.end;
      while (j < t.length &&
          styles[j] == styles[i] &&
          inComposing(j) == inComposing(i)) {
        j++;
      }
      var look = _look(styles[i], base);
      if (inComposing(i)) {
        look = look.copyWith(decoration: TextDecoration.underline);
      }
      children.add(TextSpan(text: t.substring(i, j), style: look));
      i = j;
    }
    return TextSpan(style: base, children: children);
  }
}

/// Hands every typed change to [onChange], which says what the field shows.
class _Gate extends TextInputFormatter {
  _Gate(this.onChange);

  final TextEditingValue Function(TextEditingValue old, TextEditingValue next)
  onChange;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (oldValue.text == newValue.text) return newValue;
    return onChange(oldValue, newValue);
  }
}

class _MarkdownRichEditorState extends State<MarkdownRichEditor> {
  late MdDoc _doc = MdDoc.parse(widget.text);

  /// The text this editor last sent out or read in.
  late String _known = widget.text;

  final _fields = <MdBlock, _Field>{};

  late final ScrollController _scroll =
      ScrollController(initialScrollOffset: widget.at)..addListener(() {
        if (_scroll.hasClients) widget.onScroll?.call(_scroll.offset);
      });

  /// The block last typed into and when, for coalescing undo.
  _Field? _lastField;
  DateTime _lastAt = DateTime(0);

  /// The block with the caret, for the bar.
  _Field? _active;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(MarkdownRichEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._state == this) old.controller!._state = null;
      widget.controller?._state = this;
    }
    if (widget.text != _known) _readBack(widget.text);
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    for (final field in _fields.values) {
      field.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  _Field _fieldOf(MdBlock block) => _fields.putIfAbsent(block, () {
    final field = _Field(block.inline!);
    field.focus.addListener(() {
      if (field.focus.hasFocus) _active = field;
      widget.controller?._changed();
    });
    field.controller.addListener(() => widget.controller?._changed());
    return field;
  });

  /// Keeps the fields of the blocks still there and lets the rest go.
  void _adopt(MdDoc doc, {Map<MdBlock, MdBlock> moved = const {}}) {
    for (final MapEntry(key: from, value: to) in moved.entries) {
      final field = _fields.remove(from);
      if (field != null) _fields[to] = field;
    }
    final live = doc.blocks.toSet();
    for (final block in _fields.keys.toList()) {
      if (!live.contains(block)) {
        final field = _fields.remove(block)!;
        if (_active == field) _active = null;
        if (_lastField == field) _lastField = null;
        // After the frame: the field may still be in this frame's tree.
        WidgetsBinding.instance.addPostFrameCallback((_) => field.dispose());
      }
    }
    _doc = doc;
  }

  /// [text] changed from outside: an undo, a redo, a reload or Source. The
  /// blocks that read the same keep their fields, and the first one that
  /// changed gets the caret, where the change was.
  void _readBack(String text) {
    final before = _doc.blocks;
    final hadFocus = _fields.values.any((f) => f.focus.hasFocus);
    final doc = MdDoc.parse(text);
    final moved = <MdBlock, MdBlock>{};
    int? changed;
    for (var i = 0; i < doc.blocks.length; i++) {
      final now = doc.blocks[i];
      final was = i < before.length ? before[i] : null;
      if (was != null && was.raw == now.raw && was.editable && now.editable) {
        moved[was] = now;
      } else if (changed == null && now.editable) {
        changed = i;
      }
    }
    // A field whose block changed is reused for it, so the keyboard stays up.
    if (changed != null &&
        changed < before.length &&
        before[changed].editable) {
      final was = before[changed];
      final now = doc.blocks[changed];
      final field = _fields.remove(was);
      if (field != null) {
        final old = field.controller.text;
        final next = now.inline!.text;
        var s = 0;
        while (s < old.length &&
            s < next.length &&
            old[old.length - 1 - s] == next[next.length - 1 - s]) {
          s++;
        }
        field.controller.setInline(
          now.inline!,
          selection: TextSelection.collapsed(offset: next.length - s),
        );
        _fields[now] = field;
      }
    }
    setState(() {
      _known = text;
      _adopt(doc, moved: moved);
    });
    if (hadFocus && changed != null) _focus(changed, null);
  }

  void _emit(MdChange change, {required bool typing, _Field? field}) {
    final now = DateTime.now();
    final coalesce =
        typing &&
        field != null &&
        field == _lastField &&
        now.difference(_lastAt) < const Duration(milliseconds: 1500);
    _lastField = typing ? field : null;
    _lastAt = now;
    _known = change.doc.text;
    widget.onChanged(_known, coalesce: coalesce);
  }

  int _indexOf(_Field field) =>
      _doc.blocks.indexWhere((b) => identical(_fields[b], field));

  /// Puts the caret in block [i] at [caret], its end when null.
  void _focus(int i, int? caret) {
    if (i < 0 || i >= _doc.blocks.length || !_doc.blocks[i].editable) return;
    final field = _fieldOf(_doc.blocks[i]);
    final at = (caret ?? field.controller.text.length).clamp(
      0,
      field.controller.text.length,
    );
    // After the frame, once a new block's field is built; and a frame asked
    // for, since moving between blocks that are already there changes
    // nothing that would ask for one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      field.controller.selection = TextSelection.collapsed(offset: at);
      field.focus.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  MdStyle _insertStyle(_RichTextController c, int a, int b) {
    final pending = c.pendingHere;
    if (pending != null) return pending;
    final styles = c.styles;
    if (b > a) return styles[a];
    if (styles.isEmpty) return MdStyle.plain;
    if (a == 0) {
      return styles[0].link == null ? styles[0] : styles[0].withoutLink();
    }
    final left = styles[a - 1];
    final right = a < styles.length ? styles[a] : null;
    // A link and inline code end where they end: what is typed after one is
    // plain, as in every editor.
    var style = left;
    if (left.link != null && right?.link != left.link) {
      style = style.withoutLink();
    }
    if (left.code && !(right?.code ?? false)) {
      style = style.copyWith(code: false);
    }
    return style;
  }

  /// [next] as typed into [field], made in the document: what the field
  /// shows afterwards, which is [old] where it could not be made.
  TextEditingValue _onType(
    _Field field,
    TextEditingValue old,
    TextEditingValue next,
  ) {
    final i = _indexOf(field);
    if (i < 0) return old;
    final c = field.controller;
    final o = old.text;
    final n = next.text;
    var p = 0;
    while (p < o.length && p < n.length && o[p] == n[p]) {
      p++;
    }
    if (next.selection.isCollapsed) {
      final grown = n.length - o.length;
      final cap = next.selection.baseOffset - (grown > 0 ? grown : 0);
      if (cap >= 0 && cap < p) p = cap;
    }
    var s = 0;
    while (s < o.length - p &&
        s < n.length - p &&
        o[o.length - 1 - s] == n[n.length - 1 - s]) {
      s++;
    }
    final a = p;
    final b = o.length - s;
    var ins = n.substring(p, n.length - s);

    // Enter makes a new block; Shift+Enter, a line within this one.
    if (ins == '\n' && b == a && !HardwareKeyboard.instance.isShiftPressed) {
      return _split(i, a) ?? old;
    }
    final heading = _doc.blocks[i].shape == MdBlockKind.heading;
    if (ins.contains('\n')) {
      ins = heading
          ? ins.replaceAll(RegExp(r'\s*\n\s*'), ' ')
          : ins.replaceAll(RegExp(r'\n{2,}'), '\n');
    }
    final style = _insertStyle(c, a, b);
    final text = o.replaceRange(a, b, ins);
    final styles = [
      ...c.styles.sublist(0, a),
      for (var k = 0; k < ins.length; k++) style,
      ...c.styles.sublist(b),
    ];
    final change = _doc.edit(
      i,
      MdEdit(text, styles, a: a, b: b, ins: ins, insStyle: style),
      caret: a + ins.length,
    );
    if (change == null) {
      widget.onRefused(
        "That can't be written there in Markdown. Edit it in Source.",
      );
      return old;
    }
    final block = change.doc.blocks[i];
    c.styles = List.of(block.inline!.styles);
    c.pending = null;
    setState(() => _adopt(change.doc, moved: {_doc.blocks[i]: block}));
    _emit(change, typing: true, field: field);
    // Pasted line breaks folded: the field shows what was written.
    return block.inline!.text == n
        ? next
        : TextEditingValue(
            text: block.inline!.text,
            selection: TextSelection.collapsed(offset: a + ins.length),
          );
  }

  /// Block [i] cut in two at [at]: what its field shows afterwards, the caret
  /// going on into the new block. Null where it cannot be cut there.
  TextEditingValue? _split(int i, int at) {
    final change = _doc.split(i, at);
    if (change == null) {
      widget.onRefused("A new block can't start there. Edit it in Source.");
      return null;
    }
    final old = _doc.blocks[i];
    final left = change.doc.blocks[i];
    _fields[old]?.controller.styles = List.of(left.inline!.styles);
    setState(() => _adopt(change.doc, moved: {old: left}));
    _emit(change, typing: false);
    _focus(change.block, 0);
    return TextEditingValue(
      text: left.inline!.text,
      selection: TextSelection.collapsed(offset: left.inline!.text.length),
    );
  }

  KeyEventResult _onKey(_Field field, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final command =
        defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.iOS
        ? keys.isMetaPressed
        : keys.isControlPressed;
    final key = event.logicalKey;
    if (command && !keys.isAltPressed) {
      if (key == LogicalKeyboardKey.keyZ) {
        (keys.isShiftPressed ? widget.onRedo : widget.onUndo)?.call();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        widget.onRedo?.call();
        return KeyEventResult.handled;
      }
      final mark = {
        LogicalKeyboardKey.keyB: widget.controller?.toggleBold,
        LogicalKeyboardKey.keyI: widget.controller?.toggleItalic,
        LogicalKeyboardKey.keyE: widget.controller?.toggleCode,
        LogicalKeyboardKey.keyK: widget.controller?.editLink,
      }[key];
      if (mark != null) {
        mark();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final sel = field.controller.selection;
    if (!sel.isValid || !sel.isCollapsed || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final at = sel.baseOffset;
    final end = field.controller.text.length;
    final i = _indexOf(field);
    if (i < 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.backspace && at == 0) {
      final change = _doc.mergeBack(i);
      if (change == null) return KeyEventResult.ignored;
      final into = change.block >= 0 ? change.doc.blocks[change.block] : null;
      final before = into == null ? null : _editableBefore(i);
      setState(() {
        if (into != null && before != null) {
          _adopt(change.doc, moved: {before.$1: into});
          before.$2.controller.setInline(into.inline!);
        } else {
          _adopt(change.doc);
        }
      });
      _emit(change, typing: false);
      if (change.block >= 0) _focus(change.block, change.caret);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowLeft) &&
        at == 0) {
      final prev = _neighbour(i, -1);
      if (prev == null) return KeyEventResult.ignored;
      _focus(prev, null);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowRight) &&
        at == end) {
      final next = _neighbour(i, 1);
      if (next == null) return KeyEventResult.ignored;
      _focus(next, 0);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The block before [i] that a merge goes into, with its field.
  (MdBlock, _Field)? _editableBefore(int i) {
    for (var p = i - 1; p >= 0; p--) {
      final block = _doc.blocks[p];
      if (block.kind == MdBlockKind.gap) continue;
      final field = _fields[block];
      return field == null ? null : (block, field);
    }
    return null;
  }

  int? _neighbour(int i, int step) {
    for (var k = i + step; k >= 0 && k < _doc.blocks.length; k += step) {
      final b = _doc.blocks[k];
      if (b.kind == MdBlockKind.gap) continue;
      if (b.editable) return k;
      return null;
    }
    return null;
  }

  MdStyle? _styleAtCaret() {
    final field = _active;
    if (field == null || !field.focus.hasFocus) return null;
    final c = field.controller;
    final sel = c.selection;
    // Mid-change, the text and its marks can be a frame apart.
    if (!sel.isValid ||
        c.styles.length != c.text.length ||
        sel.end > c.styles.length) {
      return null;
    }
    if (sel.isCollapsed) {
      return c.pendingHere ?? _insertStyle(c, sel.baseOffset, sel.baseOffset);
    }
    final range = c.styles.sublist(sel.start, sel.end);
    return MdStyle(
      bold: range.every((s) => s.bold),
      italic: range.every((s) => s.italic),
      code: range.every((s) => s.code),
      link: range.every((s) => s.link == range.first.link)
          ? range.first.link
          : null,
    );
  }

  void _toggle(
    MdStyle Function(MdStyle style, bool on) mark,
    bool Function(MdStyle style) has,
  ) {
    final field = _active;
    if (field == null) return;
    final c = field.controller;
    final sel = c.selection;
    if (!sel.isValid) return;
    final now = _styleAtCaret();
    if (now == null) return;
    final on = !has(now);
    if (sel.isCollapsed) {
      c.setPending(mark(now, on));
      return;
    }
    final styles = List.of(c.styles);
    for (var k = sel.start; k < sel.end; k++) {
      styles[k] = mark(styles[k], on);
    }
    _restyle(field, styles);
  }

  void _restyle(_Field field, List<MdStyle> styles) {
    final i = _indexOf(field);
    if (i < 0) return;
    final c = field.controller;
    final change = _doc.edit(i, MdEdit(c.text, styles), caret: c.selection.end);
    if (change == null) {
      widget.onRefused("Those marks can't be written there. Use Source.");
      return;
    }
    final block = change.doc.blocks[i];
    setState(() {
      _adopt(change.doc, moved: {_doc.blocks[i]: block});
      c.styles = List.of(block.inline!.styles);
    });
    c.restyled();
    _emit(change, typing: false);
  }

  Future<void> _editLink() async {
    final field = _active;
    if (field == null) return;
    final c = field.controller;
    var sel = c.selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      // In a link, the whole link; anywhere else there is nothing to link.
      final at = sel.baseOffset;
      final k = at < c.styles.length && c.styles[at].link != null ? at : at - 1;
      final link = k >= 0 && k < c.styles.length ? c.styles[k].link : null;
      if (link == null) {
        widget.onRefused('Select the text to link first.');
        return;
      }
      var s = k;
      var e = k + 1;
      while (s > 0 && c.styles[s - 1].link == link) {
        s--;
      }
      while (e < c.styles.length && c.styles[e].link == link) {
        e++;
      }
      sel = TextSelection(baseOffset: s, extentOffset: e);
    }
    final current = c.styles[sel.start].link?.href;
    final url = await widget.askLink(current);
    if (url == null || !mounted || !_fields.containsValue(field)) return;
    final styles = List.of(c.styles);
    for (var k = sel.start; k < sel.end; k++) {
      final s = styles[k];
      styles[k] = url.trim().isEmpty
          ? s.withoutLink()
          : s.copyWith(link: MdLink(url.trim()));
    }
    _restyle(field, styles);
  }

  /// The link under [global] in [field], if any.
  MdLink? _linkAt(_Field field, Offset global) {
    RenderEditable? find(RenderObject? r) {
      if (r == null) return null;
      if (r is RenderEditable) return r;
      RenderEditable? found;
      r.visitChildren((child) => found ??= find(child));
      return found;
    }

    final editable = find(field.key.currentContext?.findRenderObject());
    if (editable == null) return null;
    final position = editable.getPositionForPoint(global);
    final styles = field.controller.styles;
    final k = position.affinity == TextAffinity.upstream
        ? position.offset - 1
        : position.offset;
    if (k < 0 || k >= styles.length) return null;
    return styles[k].link;
  }

  Widget _editable(BuildContext context, int i, MdBlock block) {
    final field = _fieldOf(block);
    field.controller.sheet = widget.styleSheet;
    final sheet = widget.styleSheet;
    final style = switch (block.shape) {
      MdBlockKind.heading => switch (block.prefix.trim().length) {
        1 => sheet.h1,
        2 => sheet.h2,
        3 => sheet.h3,
        4 => sheet.h4,
        5 => sheet.h5,
        _ => sheet.h6,
      },
      _ => sheet.p,
    };
    Timer? press;
    Offset? down;
    Widget text = Listener(
      key: field.key,
      onPointerDown: (event) {
        final keys = HardwareKeyboard.instance;
        if (keys.isControlPressed || keys.isMetaPressed) {
          final link = _linkAt(field, event.position);
          if (link != null) widget.onOpenLink(link);
          return;
        }
        down = event.position;
        press?.cancel();
        press = Timer(kLongPressTimeout, () {
          final link = _linkAt(field, event.position);
          if (link == null) return;
          widget.onOpenLink(link);
          // The word the press selected goes back to a caret.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final sel = field.controller.selection;
            if (sel.isValid && !sel.isCollapsed) {
              field.controller.selection = TextSelection.collapsed(
                offset: sel.end,
              );
            }
          });
        });
      },
      onPointerMove: (event) {
        if (down != null && (event.position - down!).distance > kTouchSlop) {
          press?.cancel();
        }
      },
      onPointerUp: (_) => press?.cancel(),
      onPointerCancel: (_) => press?.cancel(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => _onKey(field, event),
        child: TextField(
          controller: field.controller,
          focusNode: field.focus,
          style: style,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          inputFormatters: [_Gate((old, next) => _onType(field, old, next))],
          decoration: const InputDecoration.collapsed(hintText: null),
        ),
      ),
    );
    if (block.shape == MdBlockKind.listItem) {
      final marker = block.prefix.trim();
      final bullet = RegExp(r'^\d').hasMatch(marker) ? marker : '•';
      text = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: sheet.listIndent ?? 24,
            child: Text(bullet, style: sheet.listBullet ?? style),
          ),
          Expanded(child: text),
        ],
      );
    }
    return text;
  }

  Widget _opaque(BuildContext context, int i, MdBlock block, String refs) {
    final p = TermulThemeData.of(context).palette;
    final source = switch (block.why) {
      MdOpaque.frontMatter || MdOpaque.reference || MdOpaque.footnote => null,
      _ => block.raw,
    };
    final drawn = source == null
        ? Text(
            block.raw.trimRight(),
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 12,
              color: p.dim,
            ),
          )
        : widget.opaqueBuilder(
            context,
            refs.isEmpty ? source : '$source\n$refs',
          );
    final indent = block.why == MdOpaque.nestedList
        ? RegExp(r'^ *').firstMatch(block.raw)![0]!.length * 8.0
        : 0.0;
    final label = block.why?.label ?? 'block';
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: drawn),
          // Quiet: an icon and its tooltip, not a banner on every table.
          IconButton(
            tooltip: 'Read-only here: edit this $label in Source',
            icon: Icon(Icons.lock_outline, size: 14, color: p.dim),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: () => widget.onEditInSource(_lineOf(i)),
          ),
        ],
      ),
    );
  }

  int _lineOf(int i) {
    var line = 1;
    for (var k = 0; k < i; k++) {
      line += '\n'.allMatches(_doc.blocks[k].raw).length;
    }
    return line;
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _doc.blocks;
    final refs = blocks
        .where((b) => b.why == MdOpaque.reference)
        .map((b) => b.raw)
        .join();
    var shown = 0;
    var size = 0;
    while (shown < blocks.length &&
        size + blocks[shown].raw.length <= MarkdownRichEditor.limit) {
      size += blocks[shown].raw.length;
      shown++;
    }
    final cut = shown < blocks.length;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 24),
      itemCount: shown + (cut ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == shown) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Only the first 100 KB is shown here. Source has the whole '
              'file.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final block = blocks[i];
        if (block.kind == MdBlockKind.gap) return const SizedBox(height: 8);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: block.editable
              ? _editable(context, i, block)
              : _opaque(context, i, block, refs),
        );
      },
    );
  }
}

/// The bar under a rich text page: undo and redo, then bold, italic, code and
/// link for the block with the caret, each lit while it is on there.
class MarkdownRichBar extends StatelessWidget {
  const MarkdownRichBar({
    super.key,
    required this.controller,
    required this.history,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
  });

  final MarkdownRichController controller;

  /// What [canUndo] and [canRedo] follow.
  final Listenable history;
  final bool Function() canUndo;
  final bool Function() canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return TextFieldTapRegion(
      child: Material(
        color: p.sidebar,
        shape: Border(top: BorderSide(color: p.border)),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 48,
            child: ListenableBuilder(
              listenable: Listenable.merge([controller, history]),
              builder: (context, _) {
                final style = controller.style;
                Widget mark(
                  String label,
                  String name,
                  bool on,
                  VoidCallback run,
                ) => KeyButton(
                  label: label,
                  logName: name,
                  active: on,
                  onTap: style == null ? () {} : run,
                );
                return ExcludeFocus(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    children: [
                      IconButton(
                        tooltip: 'Undo',
                        onPressed: canUndo() ? onUndo : null,
                        icon: const Icon(Icons.undo),
                      ),
                      IconButton(
                        tooltip: 'Redo',
                        onPressed: canRedo() ? onRedo : null,
                        icon: const Icon(Icons.redo),
                      ),
                      const SizedBox(width: 6),
                      mark(
                        'B',
                        'bold',
                        style?.bold ?? false,
                        controller.toggleBold,
                      ),
                      mark(
                        'I',
                        'italic',
                        style?.italic ?? false,
                        controller.toggleItalic,
                      ),
                      mark(
                        '</>',
                        'code',
                        style?.code ?? false,
                        controller.toggleCode,
                      ),
                      mark(
                        'LINK',
                        'link',
                        style?.link != null,
                        () => unawaited(controller.editLink()),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
