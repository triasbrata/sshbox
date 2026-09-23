// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_code_editor.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// A control's Semantics is its own node (container: true), so its word is
// not merged into whatever is around it: a screen reader, an e2e flow and a
// finder can each reach it by that word.
//
// showTuiGoToLineDialog no longer disposes its field's controller as soon
// as showDialog's future completes: that is while the dialog is still
// animating out, and its TextField, rebuilt for the animation, threw "A
// TextEditingController was used after being disposed". The controller
// holds nothing but its text and goes with the garbage.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'termul_theme.dart';
import 'tui_button.dart';
import 'tui_dialog.dart';
import 'tui_select.dart';
import 'tui_text.dart';

/// Source vs rendered Markdown.
enum TuiCodeViewMode { source, preview }

/// One display line in [TuiCodeEditor] source mode.
///
/// Host supplies [spans] for syntax colouring; otherwise [text] is plain mono.
class TuiCodeLine {
  const TuiCodeLine({required this.number, required this.text, this.spans});

  final int number;
  final String text;

  /// Optional pre-coloured content; when set, [text] is still used for search
  /// / a11y fallbacks.
  final InlineSpan? spans;
}

/// Find / replace chrome — search state is host-owned.
class TuiFindBar extends StatelessWidget {
  const TuiFindBar({
    super.key,
    required this.findController,
    this.replaceController,
    this.findFocusNode,
    this.replaceFocusNode,
    this.replaceMode = false,
    this.matchLabel = '',
    this.onPrevious,
    this.onNext,
    this.onToggleReplace,
    this.onClose,
    this.onReplace,
    this.onReplaceAll,
    this.readOnly = false,
  });

  final TextEditingController findController;
  final TextEditingController? replaceController;
  final FocusNode? findFocusNode;
  final FocusNode? replaceFocusNode;
  final bool replaceMode;
  final String matchLabel;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onToggleReplace;
  final VoidCallback? onClose;
  final VoidCallback? onReplace;
  final VoidCallback? onReplaceAll;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final mono = Theme.of(context).textTheme.bodyMedium!
        .copyWith(fontFamily: TermulFonts.mono, fontSize: 13);

    Widget field({
      required TextEditingController controller,
      FocusNode? focus,
      required String hint,
    }) => TextField(
      controller: controller,
      focusNode: focus,
      autocorrect: false,
      enableSuggestions: false,
      style: mono,
      cursorColor: p.accent,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: mono.copyWith(color: p.dim),
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );

    Widget iconBtn({
      required String label,
      required String glyph,
      VoidCallback? onPressed,
      bool selected = false,
    }) {
      final enabled = onPressed != null;
      return Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: label,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            color: selected ? p.selection : Colors.transparent,
            child: ExcludeSemantics(
              child: Text(
                glyph,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 14,
                  color: enabled ? (selected ? p.accent : p.text) : p.dim,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: p.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: field(
                      controller: findController,
                      focus: findFocusNode,
                      hint: 'Find',
                    ),
                  ),
                  if (matchLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: TuiText(matchLabel, tone: TuiTextTone.dim),
                    ),
                  iconBtn(
                    label: 'Previous match',
                    glyph: '▴',
                    onPressed: onPrevious,
                  ),
                  iconBtn(label: 'Next match', glyph: '▾', onPressed: onNext),
                  if (!readOnly)
                    iconBtn(
                      label: 'Replace',
                      glyph: '⇄',
                      selected: replaceMode,
                      onPressed: onToggleReplace,
                    ),
                  iconBtn(label: 'Close find', glyph: '×', onPressed: onClose),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            if (replaceMode && !readOnly && replaceController != null)
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: field(
                        controller: replaceController!,
                        focus: replaceFocusNode,
                        hint: 'Replace with',
                      ),
                    ),
                    TextButton(
                      onPressed: onReplace,
                      child: Text(
                        'Replace',
                        style: mono.copyWith(color: p.accent, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: onReplaceAll,
                      child: Text(
                        'All',
                        style: mono.copyWith(color: p.accent, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Prompts for a 1-based line number. Returns `null` if cancelled.
Future<int?> showTuiGoToLineDialog(
  BuildContext context, {
  int? current,
  int? max,
}) async {
  final controller = TextEditingController(
    text: current == null ? '' : '$current',
  );
  final result = await showDialog<int>(
    context: context,
    barrierColor: TermulThemeData.of(context).palette.text
        .withValues(alpha: 0.35),
    builder: (ctx) {
      return TuiDialog(
        title: 'Go to line',
        message: max == null ? null : '1 – $max',
        actions: [
          TuiButton(
            label: 'cancel',
            variant: TuiButtonVariant.ghost,
            onPressed: () => Navigator.pop(ctx),
          ),
          TuiButton(
            label: 'go',
            onPressed: () {
              final n = int.tryParse(controller.text);
              if (n != null) Navigator.pop(ctx, n);
            },
          ),
        ],
        child: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: Theme.of(ctx).textTheme.bodyMedium!
              .copyWith(fontFamily: TermulFonts.mono),
          cursorColor: TermulThemeData.of(ctx).palette.accent,
          decoration: InputDecoration(
            hintText: 'line number',
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(
                color: TermulThemeData.of(ctx).palette.border,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(
                color: TermulThemeData.of(ctx).palette.accent,
              ),
            ),
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v);
            if (n != null) Navigator.pop(ctx, n);
          },
        ),
      );
    },
  );
  if (result == null) return null;
  if (max != null && result > max) return max;
  if (result < 1) return 1;
  return result;
}

/// File chrome: mode toggle, find bar, line-numbered source or preview slot.
///
/// Presentation only — inject a real editor via [sourceChild], or pass
/// [lines] for a read-only / gallery surface. Syntax colouring is host-owned
/// ([TuiCodeLine.spans]).
class TuiCodeEditor extends StatelessWidget {
  const TuiCodeEditor({
    super.key,
    this.path,
    this.subtitle,
    this.dirty = false,
    this.readOnly = false,
    this.loading = false,
    this.binary = false,
    this.errorMessage,
    this.mode = TuiCodeViewMode.source,
    this.onModeChanged,
    this.showModeToggle = false,
    this.lines,
    this.sourceChild,
    this.previewChild,
    this.findBar,
    this.banner,
    this.highlightLine,
    this.onLineTap,
    this.gutterWidth = 44,
    this.fontSize = 13,
  });

  final String? path;

  /// Second title line — parent path, or omit when [dirty] paints “Unsaved…”.
  final String? subtitle;
  final bool dirty;
  final bool readOnly;
  final bool loading;
  final bool binary;
  final String? errorMessage;

  final TuiCodeViewMode mode;
  final ValueChanged<TuiCodeViewMode>? onModeChanged;
  final bool showModeToggle;

  /// Read-only source rows when [sourceChild] is null.
  final List<TuiCodeLine>? lines;
  final Widget? sourceChild;
  final Widget? previewChild;
  final Widget? findBar;
  final Widget? banner;

  /// 1-based line to tint (e.g. after go-to-line).
  final int? highlightLine;
  final ValueChanged<int>? onLineTap;
  final double gutterWidth;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final sub = dirty ? 'Unsaved changes' : subtitle;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (path != null || showModeToggle)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              decoration: BoxDecoration(
                color: p.surface,
                border: Border(bottom: BorderSide(color: p.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (path != null)
                          Text(
                            path!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: TermulFonts.mono,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: p.text,
                            ),
                          ),
                        if (sub != null && sub.isNotEmpty)
                          Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: TermulFonts.mono,
                              fontSize: 11,
                              color: dirty ? p.yellow : p.dim,
                            ),
                          ),
                        if (readOnly && !dirty)
                          Text(
                            'read-only',
                            style: TextStyle(
                              fontFamily: TermulFonts.mono,
                              fontSize: 11,
                              color: p.dim,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (showModeToggle)
                    TuiSelect<TuiCodeViewMode>(
                      value: mode,
                      onChanged: loading || binary || errorMessage != null
                          ? null
                          : onModeChanged,
                      options: const [
                        (TuiCodeViewMode.source, 'source'),
                        (TuiCodeViewMode.preview, 'preview'),
                      ],
                    ),
                ],
              ),
            ),
          ?banner,
          if (mode == TuiCodeViewMode.source) ?findBar,
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    if (loading) {
      return Center(
        child: Text(
          'loading…',
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 13,
            color: p.dim,
          ),
        ),
      );
    }

    if (binary) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'This looks like a binary file.\nDownload it instead of editing.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 13,
              height: 1.5,
              color: p.muted,
            ),
          ),
        ),
      );
    }

    if (errorMessage != null && errorMessage!.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            errorMessage!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 13,
              color: p.red,
            ),
          ),
        ),
      );
    }

    if (mode == TuiCodeViewMode.preview) {
      return previewChild ??
          Center(
            child: Text(
              'No preview',
              style: TextStyle(fontFamily: TermulFonts.mono, color: p.dim),
            ),
          );
    }

    if (sourceChild != null) return sourceChild!;

    final rows = lines ?? const <TuiCodeLine>[];
    if (rows.isEmpty) {
      return Center(
        child: Text(
          '(empty)',
          style: TextStyle(fontFamily: TermulFonts.mono, color: p.dim),
        ),
      );
    }

    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final line = rows[i];
        final hi = highlightLine == line.number;
        return InkWell(
          onTap: onLineTap == null ? null : () => onLineTap!(line.number),
          child: ColoredBox(
            color: hi ? p.selection : Colors.transparent,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: gutterWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8, top: 2),
                    child: Text(
                      '${line.number}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: fontSize,
                        height: 1.45,
                        color: p.dim,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      right: 12,
                      top: 2,
                      bottom: 2,
                    ),
                    child: line.spans != null
                        ? Text.rich(
                            line.spans!,
                            style: TextStyle(
                              fontFamily: TermulFonts.mono,
                              fontSize: fontSize,
                              height: 1.45,
                              color: p.text,
                            ),
                          )
                        : Text(
                            line.text,
                            style: TextStyle(
                              fontFamily: TermulFonts.mono,
                              fontSize: fontSize,
                              height: 1.45,
                              color: p.text,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// —— Markdown preview (structured blocks; host may parse or use helper) ——

sealed class TuiMarkdownBlock {
  const TuiMarkdownBlock();
}

class TuiMdHeading extends TuiMarkdownBlock {
  const TuiMdHeading(this.level, this.text);
  final int level;
  final String text;
}

class TuiMdParagraph extends TuiMarkdownBlock {
  const TuiMdParagraph(this.text);
  final String text;
}

class TuiMdCodeBlock extends TuiMarkdownBlock {
  const TuiMdCodeBlock({required this.code, this.language, this.onCopy});
  final String code;
  final String? language;
  final VoidCallback? onCopy;
}

class TuiMdImage extends TuiMarkdownBlock {
  const TuiMdImage({required this.alt, this.src, this.child});
  final String alt;
  final String? src;
  final Widget? child;
}

class TuiMdList extends TuiMarkdownBlock {
  const TuiMdList(this.items, {this.ordered = false});
  final List<String> items;
  final bool ordered;
}

class TuiMdQuote extends TuiMarkdownBlock {
  const TuiMdQuote(this.text);
  final String text;
}

class TuiMdRule extends TuiMarkdownBlock {
  const TuiMdRule();
}

/// Lightweight Markdown → blocks for demos / hosts without a parser package.
///
/// Supports headings, fenced code, images, lists, quotes, rules, paragraphs.
/// Not a full CommonMark implementation.
List<TuiMarkdownBlock> tuiMarkdownBlocksFrom(
  String source, {
  void Function(String code, String? language)? onCopyCode,
}) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final out = <TuiMarkdownBlock>[];
  var i = 0;

  while (i < lines.length) {
    final raw = lines[i];
    final line = raw.trimRight();

    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    if (line.trim() == '---' || line.trim() == '***') {
      out.add(const TuiMdRule());
      i++;
      continue;
    }

    final fence = RegExp(r'^```(\w+)?\s*$').firstMatch(line);
    if (fence != null) {
      final lang = fence.group(1);
      final buf = StringBuffer();
      i++;
      while (i < lines.length && !lines[i].trimRight().startsWith('```')) {
        if (buf.isNotEmpty) buf.writeln();
        buf.write(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // closing fence
      final code = buf.toString();
      out.add(
        TuiMdCodeBlock(
          code: code,
          language: lang,
          onCopy: onCopyCode == null ? null : () => onCopyCode(code, lang),
        ),
      );
      continue;
    }

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      out.add(TuiMdHeading(heading.group(1)!.length, heading.group(2)!.trim()));
      i++;
      continue;
    }

    final img = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)\s*$')
        .firstMatch(line.trim());
    if (img != null) {
      out.add(TuiMdImage(alt: img.group(1)!, src: img.group(2)));
      i++;
      continue;
    }

    if (line.trimLeft().startsWith('>')) {
      final buf = StringBuffer(
        line.trimLeft().replaceFirst(RegExp(r'^>\s?'), ''),
      );
      i++;
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        buf.write(' ');
        buf.write(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      out.add(TuiMdQuote(buf.toString()));
      continue;
    }

    if (RegExp(r'^\s*[-*+]\s+').hasMatch(line) ||
        RegExp(r'^\s*\d+\.\s+').hasMatch(line)) {
      final ordered = RegExp(r'^\s*\d+\.\s+').hasMatch(line);
      final items = <String>[];
      while (i < lines.length &&
          (RegExp(r'^\s*[-*+]\s+').hasMatch(lines[i]) ||
              RegExp(r'^\s*\d+\.\s+').hasMatch(lines[i]))) {
        items.add(
          lines[i].trimLeft().replaceFirst(RegExp(r'^([-*+]|\d+\.)\s+'), ''),
        );
        i++;
      }
      out.add(TuiMdList(items, ordered: ordered));
      continue;
    }

    final buf = StringBuffer(line);
    i++;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !lines[i].startsWith('#') &&
        !lines[i].trimRight().startsWith('```') &&
        !lines[i].trimLeft().startsWith('>') &&
        !RegExp(r'^\s*[-*+]\s+').hasMatch(lines[i]) &&
        !RegExp(r'^\s*\d+\.\s+').hasMatch(lines[i]) &&
        lines[i].trim() != '---') {
      buf.write(' ');
      buf.write(lines[i].trim());
      i++;
    }
    out.add(TuiMdParagraph(buf.toString()));
  }

  return out;
}

/// Read-only Markdown surface — code blocks with copy, image alt slots.
class TuiMarkdownPreview extends StatelessWidget {
  const TuiMarkdownPreview({
    super.key,
    required this.blocks,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 24),
    this.truncateMessage,
  });

  final List<TuiMarkdownBlock> blocks;
  final EdgeInsets padding;

  /// e.g. “Only the first 100 KB is shown…”
  final String? truncateMessage;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return SelectionArea(
      child: ListView(
        padding: padding,
        children: [
          if (truncateMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                truncateMessage!,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 11,
                  color: p.dim,
                ),
              ),
            ),
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _block(context, blocks[i]),
          ],
        ],
      ),
    );
  }

  Widget _block(BuildContext context, TuiMarkdownBlock block) {
    final p = TermulThemeData.of(context).palette;
    final body = Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontFamily: TermulFonts.display,
      fontSize: 14,
      height: 1.55,
      color: p.text,
    );

    return switch (block) {
      TuiMdHeading(:final level, :final text) => Text(
        text,
        style: TextStyle(
          fontFamily: TermulFonts.display,
          fontSize: switch (level) {
            1 => 28.0,
            2 => 22.0,
            3 => 18.0,
            _ => 15.0,
          },
          fontWeight: FontWeight.w600,
          height: 1.25,
          color: p.text,
        ),
      ),
      TuiMdParagraph(:final text) => Text(text, style: body),
      TuiMdQuote(:final text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: p.accent, width: 3)),
          color: p.selection.withValues(alpha: 0.35),
        ),
        child: Text(
          text,
          style: body.copyWith(color: p.muted, fontStyle: FontStyle.italic),
        ),
      ),
      TuiMdRule() => Divider(height: 1, thickness: 1, color: p.border),
      TuiMdList(:final items, :final ordered) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      ordered ? '${i + 1}.' : '•',
                      style: body.copyWith(color: p.dim),
                    ),
                  ),
                  Expanded(child: Text(items[i], style: body)),
                ],
              ),
            ),
        ],
      ),
      TuiMdImage(:final alt, :final src, :final child) =>
        child ??
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: p.border),
                color: p.surface,
              ),
              child: Text(
                alt.isEmpty ? (src ?? 'image') : alt,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 12,
                  color: p.dim,
                ),
              ),
            ),
      TuiMdCodeBlock(:final code, :final language, :final onCopy) =>
        DecoratedBox(
          decoration: BoxDecoration(
            color: p.surface,
            border: Border.all(color: p.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        language ?? 'code',
                        style: TextStyle(
                          fontFamily: TermulFonts.mono,
                          fontSize: 11,
                          color: p.dim,
                        ),
                      ),
                    ),
                    if (onCopy != null)
                      InkWell(
                        onTap: onCopy,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          child: Text(
                            'copy',
                            style: TextStyle(
                              fontFamily: TermulFonts.mono,
                              fontSize: 11,
                              color: p.accent,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: p.border),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  code,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 12,
                    height: 1.45,
                    color: p.text,
                  ),
                ),
              ),
            ],
          ),
        ),
    };
  }
}
