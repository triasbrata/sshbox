import 'package:flutter/material.dart';

import '../chat/chat_ask.dart';
import 'tui.dart';

/// A question Claude asked with AskUserQuestion, as a card: each question
/// under its header chip, its options with what each means, a field of the
/// user's own for the answer none of them is, and Send; or, once there is an
/// answer, the answer, as it was given.
///
/// Everything in it was written by Claude, so it is text here and nothing
/// more. [onAnswer] and [onDecline] answer it here, and [hint] says where
/// else a question nobody here can answer is to be answered.
///
/// TODO(termul): termul has no radio button, so a single choice is a
/// checkbox row that lets go of the others.
class ChatAskCard extends StatefulWidget {
  const ChatAskCard({
    super.key,
    required this.ask,
    required this.onAnswer,
    required this.onDecline,
    this.hint,
  });

  final ChatAsk ask;
  final bool Function(ChatAsk ask, Map<String, String> answers) onAnswer;
  final bool Function(ChatAsk ask) onDecline;

  /// Shown instead of the buttons when this chat cannot answer an open
  /// question: where to.
  final String? hint;

  @override
  State<ChatAskCard> createState() => _ChatAskCardState();
}

class _ChatAskCardState extends State<ChatAskCard> {
  late final List<Set<int>> _picked = [
    for (final _ in widget.ask.questions) <int>{},
  ];
  late final List<TextEditingController> _other = [
    for (final _ in widget.ask.questions) TextEditingController(),
  ];

  @override
  void dispose() {
    for (final controller in _other) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _complete {
    final questions = widget.ask.questions;
    for (var i = 0; i < questions.length; i++) {
      if (_picked[i].isEmpty && _other[i].text.trim().isEmpty) return false;
    }
    return true;
  }

  void _pick(int q, int option, bool on) => setState(() {
    final question = widget.ask.questions[q];
    if (question.multiSelect) {
      on ? _picked[q].add(option) : _picked[q].remove(option);
    } else {
      _picked[q]
        ..clear()
        ..addAll(on ? [option] : const []);
      // One answer: a pick and words of one's own would be two.
      if (on) _other[q].clear();
    }
  });

  void _send() {
    final questions = widget.ask.questions;
    final answers = <String, String>{};
    for (var i = 0; i < questions.length; i++) {
      final labels = [
        for (final index in (_picked[i].toList()..sort()))
          questions[i].options[index].label,
      ];
      answers[questions[i].question] = ChatAsk.answerOf(
        questions[i],
        labels,
        _other[i].text,
      );
    }
    widget.onAnswer(widget.ask, answers);
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final ask = widget.ask;
    final answered = ask.answers;
    final asking = ask.answerable;
    final footer = asking || answered != null
        ? null
        : ask.declined
        ? 'Dismissed without an answer.'
        : widget.hint ?? 'Waiting for an answer.';
    return Semantics(
      container: true,
      label: 'Claude asks a question',
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: p.panel,
          border: Border.all(color: asking ? p.accent : p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var q = 0; q < ask.questions.length; q++) ...[
              if (q > 0) const SizedBox(height: 12),
              _question(context, q, answered, asking),
            ],
            if (asking) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _KeyButton(
                    onPressed: _complete ? _send : null,
                    child: TuiButton(
                      label: 'Send answers', logName: 'Send answers',
                      onPressed: _complete ? _send : null,
                    ),
                  ),
                  _KeyButton(
                    onPressed: () => widget.onDecline(ask),
                    child: TuiButton(
                      label: 'Dismiss', logName: 'Dismiss',
                      variant: TuiButtonVariant.ghost,
                      onPressed: () => widget.onDecline(ask),
                    ),
                  ),
                ],
              ),
            ],
            if (footer != null) ...[
              const SizedBox(height: 8),
              // A node of its own: inside the card's, plain text is merged into
              // one label, and what it says would not be found by itself.
              Semantics(
                container: true,
                child: TuiText(footer, tone: TuiTextTone.dim, size: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _question(
    BuildContext context,
    int q,
    Map<String, String>? answered,
    bool asking,
  ) {
    final p = TermulThemeData.of(context).palette;
    final question = widget.ask.questions[q];
    final answer = answered?[question.question];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (question.header.isNotEmpty)
              TuiBadge(label: question.header, tone: TuiTextTone.accent),
            if (question.multiSelect)
              const TuiText('choose any', tone: TuiTextTone.dim, size: 11),
          ],
        ),
        const SizedBox(height: 4),
        SelectableText(
          question.question,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: p.text,
          ),
        ),
        const SizedBox(height: 6),
        if (answer != null)
          // What was given, which may be an option's label or the user's own
          // words.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TuiText('→ ', tone: TuiTextTone.accent, size: 13),
              Expanded(child: SelectableText(answer)),
            ],
          )
        else ...[
          for (var o = 0; o < question.options.length; o++)
            _option(context, q, o, asking),
          if (asking)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextField(
                controller: _other[q],
                onChanged: (text) => setState(() {
                  // One answer: words of one's own let go of a pick.
                  if (!question.multiSelect && text.isNotEmpty) {
                    _picked[q].clear();
                  }
                }),
                decoration: InputDecoration(
                  isDense: true,
                  prefixText: '❯ ',
                  prefixStyle: TextStyle(
                    fontFamily: TermulFonts.mono,
                    color: p.accent,
                  ),
                  hintText: 'Other…',
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _option(BuildContext context, int q, int o, bool asking) {
    final question = widget.ask.questions[q];
    final option = question.options[o];
    final chosen = _picked[q].contains(o);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TuiText(option.label, bold: true, size: 13),
        if (option.description.isNotEmpty)
          TuiText(option.description, tone: TuiTextTone.muted, size: 12),
        if (option.preview != null && (chosen || !asking))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _Preview(option.preview!),
          ),
      ],
    );
    if (!asking) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TuiText('• ', tone: TuiTextTone.dim, size: 13),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Semantics(
      container: true,
      button: true,
      checked: chosen,
      label: option.label,
      // Read with it: what the option means is part of choosing it, and the
      // text under ExcludeSemantics below is not in the tree.
      hint: option.description.isEmpty ? null : option.description,
      child: InkWell(
        onTap: () => _pick(q, o, !chosen),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: ExcludeSemantics(
            child: TuiCheckboxRow(
              value: chosen,
              onChanged: (on) => _pick(q, o, on ?? false),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// A termul button the keyboard can reach: Tab moves to it, Enter and Space
/// press it, and an outline shows where it is. termul's own TuiButton takes
/// taps only.
///
/// TODO(termul): a focusable TuiButton, which would make this unneeded.
class _KeyButton extends StatefulWidget {
  const _KeyButton({required this.onPressed, required this.child});

  final VoidCallback? onPressed;
  final Widget child;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final enabled = widget.onPressed != null;
    return FocusableActionDetector(
      enabled: enabled,
      onShowFocusHighlight: (on) => setState(() => _focused = on),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _focused ? Border.all(color: p.accent, width: 2) : null,
        ),
        child: widget.child,
      ),
    );
  }
}

/// An option's preview, as the text it is.
class _Preview extends StatelessWidget {
  const _Preview(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.border),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: TermulFonts.mono,
          fontSize: 12,
          color: p.text,
          height: 1.3,
        ),
      ),
    );
  }
}
