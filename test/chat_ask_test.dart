import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/chat_ask.dart';
import 'package:sshbox/src/ui/chat_ask_card.dart';

/// A question input as 2.1.287 sent it, measured against a real claude -p.
Map<String, dynamic> _input() => {
  'questions': [
    {
      'question': 'Which colours?',
      'header': 'Colours',
      'multiSelect': true,
      'options': [
        {'label': 'Red', 'description': 'A warm colour.'},
        {'label': 'Blue', 'description': 'A cool colour.'},
        {'label': 'Green', 'description': 'A leafy colour.'},
      ],
    },
    {
      'question': 'Which size?',
      'header': 'Size',
      'multiSelect': false,
      'options': [
        {'label': 'Small', 'description': 'Small.'},
        {'label': 'Large', 'description': 'Large.', 'preview': 'XL\n  L'},
      ],
    },
  ],
};

ChatAsk _ask([Map<String, dynamic>? input, String? requestId = 'r1']) =>
    ChatAsk.parse('toolu_1', input ?? _input())!..requestId = requestId;

void main() {
  group('reading a question', () {
    test('keeps its questions, options, descriptions and previews', () {
      final ask = _ask();
      expect(ask.questions, hasLength(2));
      expect(ask.questions[0].multiSelect, isTrue);
      expect(ask.questions[0].options.map((o) => o.label), [
        'Red',
        'Blue',
        'Green',
      ]);
      expect(ask.questions[1].options[1].preview, 'XL\n  L');
      expect(ask.questions[0].options[0].preview, isNull);
      expect(ask.input, _input());
    });

    test('takes only text, bounded, with control characters out, and drops '
        'what is not a question', () {
      final ask = ChatAsk.parse('t', {
        'questions': [
          {
            'question': 'Run this?\x1b[31m\x07',
            'header': 'A header that is far too long to be a chip ' * 3,
            'options': [
              {'label': 'Yes\x00', 'description': 'x' * 5000},
              {'label': '', 'description': 'no label: dropped'},
              'not an option',
              {'label': 7},
            ],
          },
          {'question': 42},
          'not a question',
          {'question': '   '},
        ],
      })!;

      expect(ask.questions, hasLength(1));
      final q = ask.questions.single;
      expect(q.question, 'Run this?[31m');
      expect(q.header.length, lessThanOrEqualTo(41));
      expect(q.options.single.label, 'Yes');
      expect(q.options.single.description.length, lessThanOrEqualTo(2001));
      expect(q.multiSelect, isFalse);
    });

    test('a call with no question in it is not one', () {
      expect(ChatAsk.parse('t', null), isNull);
      expect(ChatAsk.parse('t', {'questions': []}), isNull);
      expect(ChatAsk.parse('t', {'questions': 'x'}), isNull);
      expect(ChatAsk.parse('t', {'other': 1}), isNull);
    });

    test('a question of free text only has no options, and still reads', () {
      final ask = ChatAsk.parse('t', {
        'questions': [
          {'question': 'Your name?', 'kind': 'text'},
        ],
      })!;
      expect(ask.questions.single.options, isEmpty);
    });

    test(
      'the answers in a result are only strings, and none in a dismissal',
      () {
        expect(
          ChatAsk.answersIn({
            'questions': const [],
            'answers': {'Q': 'A', 'R': 3, 4: 'x'},
          }),
          {'Q': 'A'},
        );
        expect(ChatAsk.answersIn('Error: The user dismissed it'), isNull);
        expect(ChatAsk.answersIn({'questions': const []}), isNull);
      },
    );

    test('an answer is the labels joined as the CLI joins them, or the '
        'user\'s own words', () {
      final multi = _ask().questions[0];
      final single = _ask().questions[1];
      expect(ChatAsk.answerOf(multi, ['Red', 'Blue'], ''), 'Red, Blue');
      expect(ChatAsk.answerOf(multi, ['Red'], ' and teal '), 'Red, and teal');
      expect(ChatAsk.answerOf(multi, [], 'only mine'), 'only mine');
      expect(ChatAsk.answerOf(single, ['Small'], ''), 'Small');
      expect(ChatAsk.answerOf(single, ['Small'], 'Gigantic'), 'Gigantic');
    });
  });

  group('the card', () {
    Future<List<Map<String, String>>> pump(
      WidgetTester tester,
      ChatAsk ask, {
      String? hint,
      bool sends = true,
    }) async {
      final sent = <Map<String, String>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatAskCard(
                ask: ask,
                hint: hint,
                onAnswer: (_, answers) {
                  sent.add(answers);
                  return sends;
                },
                onDecline: (_) => true,
              ),
            ),
          ),
        ),
      );
      return sent;
    }

    testWidgets('shows each question under its chip, its options with what '
        'they mean, and a field of one\'s own', (tester) async {
      await pump(tester, _ask());

      expect(find.text('Colours'), findsOneWidget);
      expect(find.text('Size'), findsOneWidget);
      expect(find.text('Which colours?'), findsOneWidget);
      expect(find.text('choose any'), findsOneWidget);
      expect(find.text('Red'), findsOneWidget);
      expect(find.text('A cool colour.'), findsOneWidget);
      expect(find.text('Other…'), findsNWidgets(2));
      // A preview shows with its option once that is chosen, not before.
      expect(find.text('XL\n  L'), findsNothing);
      await tester.tap(find.text('Large'));
      await tester.pump();
      expect(find.text('XL\n  L'), findsOneWidget);
    });

    testWidgets('an option is read with what it means, as one node a screen '
        'reader and a flow can find', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, _ask());

      final blue = tester.getSemantics(find.bySemanticsLabel('Blue'));
      expect(blue.label, 'Blue');
      expect(blue.hint, 'A cool colour.');
      semantics.dispose();
    });

    testWidgets('Send waits for every question to have an answer, then '
        'sends a multiple choice joined and a single one alone', (
      tester,
    ) async {
      final sent = await pump(tester, _ask());
      Finder send() => find.bySemanticsLabel('Send answers');

      await tester.tap(send());
      await tester.pump();
      expect(sent, isEmpty);

      await tester.tap(find.text('Red'));
      await tester.tap(find.text('Green'));
      await tester.pump();
      await tester.tap(send());
      await tester.pump();
      // The second question is still unanswered.
      expect(sent, isEmpty);

      await tester.tap(find.text('Small'));
      await tester.pump();
      await tester.tap(send());
      await tester.pump();
      expect(sent.single, {
        'Which colours?': 'Red, Green',
        'Which size?': 'Small',
      });
    });

    testWidgets('a single choice lets go of one pick for another, and of '
        'both for words of one\'s own', (tester) async {
      final sent = await pump(tester, _ask());
      await tester.tap(find.text('Red'));
      await tester.tap(find.text('Small'));
      await tester.tap(find.text('Large'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send answers'));
      await tester.pump();
      expect(sent.last['Which size?'], 'Large');

      await tester.enterText(find.byType(TextField).last, 'Gigantic');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send answers'));
      await tester.pump();
      expect(sent.last['Which size?'], 'Gigantic');
      // And a pick after words gives them up.
      await tester.tap(find.text('Small'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send answers'));
      await tester.pump();
      expect(sent.last['Which size?'], 'Small');
    });

    testWidgets('words of one\'s own beside the picks of a multiple choice', (
      tester,
    ) async {
      final sent = await pump(tester, _ask());
      await tester.tap(find.text('Blue'));
      await tester.enterText(find.byType(TextField).first, 'teal');
      await tester.tap(find.text('Small'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send answers'));
      await tester.pump();
      expect(sent.single['Which colours?'], 'Blue, teal');
    });

    testWidgets('once answered it shows what was given, as given, and no '
        'buttons', (tester) async {
      final ask = _ask()
        ..requestId = null
        ..answers = {'Which colours?': 'Red, Blue', 'Which size?': 'My own'};
      await pump(tester, ask);

      expect(find.text('Which colours?'), findsOneWidget);
      expect(find.text('Red, Blue'), findsOneWidget);
      expect(find.text('My own'), findsOneWidget);
      expect(find.bySemanticsLabel('Send answers'), findsNothing);
      expect(find.bySemanticsLabel('Dismiss'), findsNothing);
      expect(find.text('Blue'), findsNothing);
    });

    testWidgets('a question nobody here can answer shows its options and '
        'says where to answer it', (tester) async {
      final ask = _ask(null, null);
      await pump(tester, ask, hint: 'Answer it at claude attach 9e1f2a3b.');

      expect(find.text('Red'), findsOneWidget);
      expect(find.text('Answer it at claude attach 9e1f2a3b.'), findsOneWidget);
      expect(find.bySemanticsLabel('Send answers'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a dismissed one says so', (tester) async {
      final ask = _ask(null, null)..declined = true;
      final semantics = tester.ensureSemantics();
      await pump(tester, ask, hint: 'ignored once it has ended');
      expect(find.text('Dismissed without an answer.'), findsOneWidget);
      // Found by itself, as a flow and a screen reader look for it.
      expect(
        find.bySemanticsLabel('Dismissed without an answer.'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('Dismiss declines it', (tester) async {
      final declined = <ChatAsk>[];
      final ask = _ask();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatAskCard(
                ask: ask,
                onAnswer: (_, _) => true,
                onDecline: (a) {
                  declined.add(a);
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('Dismiss'));
      await tester.pump();
      expect(declined, [ask]);
    });
  });
}
