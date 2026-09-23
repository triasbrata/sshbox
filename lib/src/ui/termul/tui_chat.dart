// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_chat.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// A control's Semantics is its own node (container: true), so its word is
// not merged into whatever is around it: a screen reader, an e2e flow and a
// finder can each reach it by that word.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_chrome.dart';
import 'tui_text.dart';

/// Delivery state for a user [TuiChatBubble].
enum TuiChatDelivery { sending, queued, failed }

/// Tool call lifecycle for [TuiToolRow].
enum TuiToolStatus { running, done, failed }

/// Session row kind for [TuiChatSessionList].
enum TuiChatSessionKind { pinned, running, finished }

/// User message bubble — right-aligned, sharp panel.
///
/// Delivery notes sit under the bubble until the host clears them.
class TuiChatBubble extends StatelessWidget {
  const TuiChatBubble({
    super.key,
    required this.text,
    this.delivery,
    this.failureReason,
    this.selectable = true,
  });

  final String text;
  final TuiChatDelivery? delivery;
  final String? failureReason;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final failed = delivery == TuiChatDelivery.failed;
    final pending = delivery != null;
    final note = switch (delivery) {
      TuiChatDelivery.sending => 'Sending…',
      TuiChatDelivery.queued =>
        'Queued: it runs after what the session is doing.',
      TuiChatDelivery.failed => failureReason ?? 'Not delivered.',
      null => null,
    };

    final bodyStyle = TextStyle(
      fontFamily: TermulFonts.display,
      fontSize: 14,
      height: 1.45,
      color: failed
          ? (p.isLight ? p.panel : p.bg)
          : (p.isLight ? p.panel : p.bg),
    );

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: failed ? p.deep : p.accent,
        border: Border.all(color: failed ? p.deep : p.accent),
      ),
      child: selectable
          ? SelectableText(text, style: bodyStyle)
          : Text(text, style: bodyStyle),
    );

    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8, left: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(opacity: pending ? 0.65 : 1, child: bubble),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  note,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 11,
                    color: failed ? p.red : p.dim,
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Agent reply surface — host supplies Markdown / rich child, or [text].
class TuiChatAnswer extends StatelessWidget {
  const TuiChatAnswer({
    super.key,
    this.text,
    this.child,
    this.streaming = false,
  }) : assert(text != null || child != null);

  final String? text;
  final Widget? child;

  /// Shows a trailing caret while tokens stream in.
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (child != null)
              child!
            else
              Text(
                text!,
                style: TextStyle(
                  fontFamily: TermulFonts.display,
                  fontSize: 14,
                  height: 1.55,
                  color: p.text,
                ),
              ),
            if (streaming)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '▍',
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 13,
                    color: p.accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Glyph for a common coding-agent tool name.
String tuiToolGlyph(String name) => switch (name) {
  'Bash' || 'BashOutput' || 'KillShell' => r'$',
  'Read' || 'NotebookEdit' => '◇',
  'Edit' || 'MultiEdit' || 'Write' => '✎',
  'Grep' || 'Glob' => '/',
  'WebFetch' || 'WebSearch' => '@',
  'Task' => '⊞',
  'TodoWrite' => '☑',
  _ => '▸',
};

/// Expandable tool call row — name, summary, optional input/result.
class TuiToolRow extends StatefulWidget {
  const TuiToolRow({
    super.key,
    required this.name,
    required this.summary,
    this.status = TuiToolStatus.done,
    this.input,
    this.result,
    this.initiallyExpanded = false,
    this.onExpandedChanged,
    this.glyph,
    this.resultMaxHeight = 240,
  });

  final String name;
  final String summary;
  final TuiToolStatus status;

  /// Plain dump of tool args (host may prettify).
  final String? input;
  final String? result;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpandedChanged;

  /// Override lead glyph; defaults via [tuiToolGlyph].
  final String? glyph;
  final double resultMaxHeight;

  @override
  State<TuiToolRow> createState() => _TuiToolRowState();
}

class _TuiToolRowState extends State<TuiToolRow> {
  late bool _open = widget.initiallyExpanded;

  @override
  void didUpdateWidget(TuiToolRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _open = widget.initiallyExpanded;
    }
  }

  void _toggle() {
    setState(() => _open = !_open);
    widget.onExpandedChanged?.call(_open);
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final failed = widget.status == TuiToolStatus.failed;
    final running = widget.status == TuiToolStatus.running;
    final mark = widget.glyph ?? tuiToolGlyph(widget.name);
    final markColor = failed
        ? p.red
        : running
        ? p.accent
        : p.accent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.surface,
          border: Border.all(color: p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: running
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: p.accent,
                              ),
                            )
                          : Text(
                              mark,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: TermulFonts.mono,
                                fontSize: 13,
                                color: markColor,
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.name,
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: TermulFonts.mono,
                          fontSize: 11,
                          color: p.dim,
                        ),
                      ),
                    ),
                    Text(
                      _open ? '▾' : '▸',
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 12,
                        color: p.dim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_open) ...[
              if (widget.input != null && widget.input!.isNotEmpty)
                _ToolBlock(
                  label: 'input',
                  text: widget.input!,
                  maxHeight: widget.resultMaxHeight,
                ),
              if (widget.result != null && widget.result!.isNotEmpty)
                _ToolBlock(
                  label: 'result',
                  text: widget.result!,
                  maxHeight: widget.resultMaxHeight,
                  danger: failed,
                ),
              if ((widget.input == null || widget.input!.isEmpty) &&
                  (widget.result == null || widget.result!.isEmpty))
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Text(
                    running ? 'Running…' : '(no payload)',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 11,
                      color: p.dim,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolBlock extends StatelessWidget {
  const _ToolBlock({
    required this.label,
    required this.text,
    required this.maxHeight,
    this.danger = false,
  });

  final String label;
  final String text;
  final double maxHeight;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 10,
              letterSpacing: 0.6,
              color: p.dim,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxHeight),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: p.panel,
              border: Border.all(color: p.border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 11,
                  height: 1.4,
                  color: danger ? p.red : p.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row in [TuiChatSessionList].
class TuiChatSession {
  const TuiChatSession({
    required this.id,
    required this.title,
    required this.kind,
    this.subtitle,
    this.selected = false,
  });

  final String id;
  final String title;
  final TuiChatSessionKind kind;
  final String? subtitle;
  final bool selected;
}

/// Session rail — pinned / running / finished sections.
///
/// Use as a sidebar on wide layouts or inside a drawer on narrow ones.
class TuiChatSessionList extends StatelessWidget {
  const TuiChatSessionList({
    super.key,
    required this.sessions,
    this.title = 'Sessions',
    this.hint,
    this.onSelect,
    this.onNewChat,
    this.onRefresh,
    this.loading = false,
    this.errorMessage,
    this.emptyMessage = 'No sessions yet.',
    this.width = 260,
  });

  final List<TuiChatSession> sessions;
  final String title;
  final String? hint;
  final ValueChanged<TuiChatSession>? onSelect;
  final VoidCallback? onNewChat;
  final VoidCallback? onRefresh;
  final bool loading;
  final String? errorMessage;
  final String emptyMessage;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final pinned = sessions.where((s) => s.kind == TuiChatSessionKind.pinned);
    final running = sessions.where((s) => s.kind == TuiChatSessionKind.running);
    final finished = sessions.where(
      (s) => s.kind == TuiChatSessionKind.finished,
    );

    final items = <Widget>[
      if (pinned.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TuiSectionLabel('Pinned'),
        ),
        for (final s in pinned) _SessionRow(session: s, onSelect: onSelect),
      ],
      if (running.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TuiSectionLabel('Running'),
        ),
        for (final s in running) _SessionRow(session: s, onSelect: onSelect),
      ],
      if (finished.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TuiSectionLabel('Finished (${finished.length})'),
        ),
        for (final s in finished) _SessionRow(session: s, onSelect: onSelect),
      ],
    ];

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                ),
                if (onNewChat != null)
                  _IconGlyph(
                    label: 'New chat',
                    glyph: '+',
                    onPressed: onNewChat,
                  ),
                if (onRefresh != null)
                  _IconGlyph(
                    label: 'Refresh',
                    glyph: '↻',
                    onPressed: onRefresh,
                  ),
              ],
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                hint!,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 10,
                  color: p.dim,
                  height: 1.4,
                ),
              ),
            ),
          Divider(height: 1, thickness: 1, color: p.border),
          Expanded(
            child: loading
                ? Center(
                    child: Text(
                      'loading…',
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        color: p.dim,
                      ),
                    ),
                  )
                : errorMessage != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: TermulFonts.mono,
                          fontSize: 12,
                          color: p.red,
                        ),
                      ),
                    ),
                  )
                : items.isEmpty
                ? Center(
                    child: Text(
                      emptyMessage,
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 12,
                        color: p.dim,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    children: items,
                  ),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onSelect});

  final TuiChatSession session;
  final ValueChanged<TuiChatSession>? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final sel = session.selected;
    final mark = switch (session.kind) {
      TuiChatSessionKind.pinned => '★',
      TuiChatSessionKind.running => '●',
      TuiChatSessionKind.finished => '○',
    };

    return InkWell(
      onTap: onSelect == null ? null : () => onSelect!(session),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: sel ? p.selection : Colors.transparent,
        child: Row(
          children: [
            Text(
              mark,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 11,
                color: session.kind == TuiChatSessionKind.running
                    ? p.green
                    : sel
                    ? p.accent
                    : p.dim,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TuiText(
                    session.title,
                    size: 12,
                    bold: sel,
                    tone: sel ? TuiTextTone.accent : TuiTextTone.normal,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (session.subtitle != null)
                    TuiText(
                      session.subtitle!,
                      size: 10,
                      tone: TuiTextTone.dim,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconGlyph extends StatelessWidget {
  const _IconGlyph({
    required this.label,
    required this.glyph,
    required this.onPressed,
  });

  final String label;
  final String glyph;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Semantics(
      container: true,
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: ExcludeSemantics(
              child: Text(
                glyph,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 14,
                  color: onPressed == null ? p.dim : p.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
