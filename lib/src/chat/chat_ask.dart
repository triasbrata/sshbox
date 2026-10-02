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
