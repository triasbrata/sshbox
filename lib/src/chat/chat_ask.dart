/// The AskUserQuestion tool, as a chat draws it: Claude asks the user one to
/// four questions, each with a few options, and goes on with what comes back.
///
/// Everything in a question is text Claude wrote, possibly from what it read
/// on the host, so it is drawn as text and never run: [ChatAsk.parse] keeps
/// only strings, bounded, with control characters taken out.
///
/// Measured on 2.1.287 against `claude -p --input-format stream-json
/// --permission-prompt-tool stdio`:
/// - the call is an assistant `tool_use` named AskUserQuestion whose input
///   is `{questions: [{question, header, options: [{label, description,
///   preview?}], multiSelect}]}`;
/// - the CLI then sends a `control_request` of subtype `can_use_tool` with
///   the same input, that tool_use's id and `requires_user_interaction`, and
///   waits for the host's `control_response`;
/// - `{behavior: allow, updatedInput: {...input, answers: {question text:
///   answer}}}` answers it: a multiSelect answer is the chosen labels
///   joined by `, `, and an answer of the user's own is just their text;
/// - `{behavior: deny, message}` declines it, and Claude is told the message;
/// - the transcript's tool_result user line carries `tool_use_result` (in the
///   transcript file `toolUseResult`) as `{questions, answers}` for an
///   answer, and as the string `Error: ` and the message for a decline.
library;

/// One option of a question.
class AskOption {
  const AskOption({required this.label, this.description = '', this.preview});

  final String label;
  final String description;

  /// What picking it would show, as text: a code sample, a layout.
  final String? preview;
}

/// One question.
class AskQuestion {
  const AskQuestion({
    required this.question,
    required this.header,
    required this.options,
    required this.multiSelect,
  });

  /// The text of the question, which is also what an answer is filed under.
  final String question;

  /// The chip above it: one or two words.
  final String header;
  final List<AskOption> options;
  final bool multiSelect;
}

/// A question Claude asked, in the transcript.
class ChatAsk {
  ChatAsk({
    required this.toolUseId,
    required this.questions,
    required this.input,
  });

  /// The tool call this is, which the CLI's request and the answer name.
  final String toolUseId;
  final List<AskQuestion> questions;

  /// The input as it came, which an answer sends back with `answers` added.
  final Map<String, dynamic> input;

  /// The CLI's request for an answer, while it is waiting on this chat for
  /// one. Null when nobody asked this chat — a transcript read back, a
  /// session somebody watches, one the CLI has since withdrawn.
  String? requestId;

  /// What was answered, by question text, once it was.
  Map<String, String>? answers;

  /// Which process asked, as `ClaudeChat` numbers them: an answer goes only
  /// to that one.
  int? target;

  /// Whether the question was dismissed without an answer.
  bool declined = false;

  /// While an answer is being typed into the dialog of a session this chat
  /// watches, see `ClaudeChat.answerAtTerminal`.
  bool sending = false;

  /// Why the last answer typed at a session's dialog did not land, said on
  /// the card until another goes or the question is settled.
  String? failure;

  /// Whether this chat can answer it now: the CLI is waiting on it, and it
  /// has not been answered or dismissed. Two questions with one text share
  /// an answer, which is how the CLI files them; better that than leaving it
  /// waiting.
  bool get answerable => requestId != null && answers == null && !declined;

  /// Whether it is still waiting on somebody, here or elsewhere.
  bool get open => answers == null && !declined;

  static const _maxQuestions = 8;
  static const _maxOptions = 16;
  static const _maxText = 2000;
  static const _maxPreview = 4000;

  /// Control characters, tab and newline kept for a preview.
  static final _controls = RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]');

  static String _text(Object? value, int limit) {
    if (value is! String) return '';
    final clean = value.replaceAll(_controls, '');
    return clean.length > limit ? '${clean.substring(0, limit)}…' : clean;
  }

  /// The question in [input], or null when it holds none to ask.
  static ChatAsk? parse(String toolUseId, Object? input) {
    if (input is! Map<String, dynamic>) return null;
    final rows = input['questions'];
    if (rows is! List) return null;
    final questions = <AskQuestion>[];
    for (final row in rows.take(_maxQuestions)) {
      if (row is! Map<String, dynamic>) continue;
      final text = _text(row['question'], _maxText).trim();
      if (text.isEmpty) continue;
      final options = <AskOption>[];
      if (row['options'] case final List listed) {
        for (final option in listed.take(_maxOptions)) {
          if (option is! Map<String, dynamic>) continue;
          final label = _text(option['label'], _maxText).trim();
          if (label.isEmpty) continue;
          final preview = _text(option['preview'], _maxPreview);
          options.add(
            AskOption(
              label: label,
              description: _text(option['description'], _maxText),
              preview: preview.isEmpty ? null : preview,
            ),
          );
        }
      }
      questions.add(
        AskQuestion(
          question: text,
          header: _text(row['header'], 40).trim(),
          options: options,
          multiSelect: row['multiSelect'] == true,
        ),
      );
    }
    if (questions.isEmpty) return null;
    return ChatAsk(toolUseId: toolUseId, questions: questions, input: input);
  }

  /// The answers in a tool result's `{questions, answers}`, or null when it
  /// holds none: a decline is an error string instead.
  static Map<String, String>? answersIn(Object? result) {
    if (result is! Map<String, dynamic>) return null;
    final answers = result['answers'];
    if (answers is! Map) return null;
    return {
      for (final entry in answers.entries)
        if (entry.key is String && entry.value is String)
          _text(entry.key, _maxText): _text(entry.value, _maxText),
    };
  }

  /// What one question's answer reads as: [labels] chosen, joined as the CLI
  /// joins a multiSelect, or the user's own [other] text in their place for a
  /// single choice and beside them for several.
  static String answerOf(
    AskQuestion question,
    Iterable<String> labels,
    String other,
  ) {
    final own = other.trim();
    if (!question.multiSelect) return own.isNotEmpty ? own : labels.first;
    return [...labels, if (own.isNotEmpty) own].join(', ');
  }
}

/// What the user picked for one question: the options by index, and words
/// of their own, empty when none.
typedef AskPick = ({List<int> options, String other});

/// The answers [picks] make for [ask], by question text, as the CLI files
/// them; or null when they are not an answer to it: a pick for each question
/// and no more, each in range and none twice, a single choice one option or
/// words of its own, every question answered.
Map<String, String>? answersFor(ChatAsk ask, List<AskPick> picks) {
  if (picks.length != ask.questions.length) return null;
  final answers = <String, String>{};
  for (var i = 0; i < picks.length; i++) {
    final question = ask.questions[i];
    final pick = picks[i];
    final options = pick.options.toSet().toList()..sort();
    if (options.length != pick.options.length) return null;
    if (options.any((at) => at < 0 || at >= question.options.length)) {
      return null;
    }
    final own = pick.other.trim().isNotEmpty;
    if (options.isEmpty && !own) return null;
    if (!question.multiSelect && options.length + (own ? 1 : 0) != 1) {
      return null;
    }
    answers[question.question] = ChatAsk.answerOf(question, [
      for (final at in options) question.options[at].label,
    ], pick.other);
  }
  return answers;
}

/// One step of typing an answer into a session's own question dialog.
sealed class AskStep {
  const AskStep();

  /// What is written to the session's terminal for it.
  String get bytes;
}

/// Keys, as a terminal sends them: an arrow, Enter, a space. Never text of
/// the user's or Claude's: that is an [AskPaste].
class AskKeys extends AskStep {
  const AskKeys(this.keys);

  final String keys;

  @override
  String get bytes => keys;
}

/// Words of the user's own, for an "Other" answer: one bracketed paste, so
/// none of it is taken for the dialog's own keys, which include single
/// letters. Every control character goes, newline and tab included, each
/// becoming a space: the answer is one line, and an ESC left in it could
/// close the paste early and have the rest typed as keys.
class AskPaste extends AskStep {
  const AskPaste(this.text);

  final String text;

  static final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  /// [text] as it goes in, with nothing in it a terminal would act on.
  String get clean => text.replaceAll(_controls, ' ').trim();

  @override
  String get bytes => '\x1b[200~$clean\x1b[201~';
}

/// Whether a session's screen, as [lines], shows [question]'s dialog: its
/// text there, compared with all white space taken out of both, so a
/// question the dialog wraps across lines still matches. Only the first 120
/// characters are looked for, as a long question may be cut on screen.
bool dialogShows(List<String> lines, AskQuestion question) {
  String bare(String text) => text.replaceAll(RegExp(r'\s+'), '');
  final wanted = bare(question.question);
  if (wanted.isEmpty) return false;
  final head = wanted.length > 120 ? wanted.substring(0, 120) : wanted;
  return bare(lines.join()).contains(head);
}
