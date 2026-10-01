import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/ui/slash_command_menu.dart';

/// Rows as Claude Code 2.1.286 answered `initialize`, descriptions cut.
const _rows = [
  {
    'name': 'compact',
    'description': 'Free up context by summarizing the conversation so far',
    'argumentHint': '<optional custom summarization instructions>',
    'builtin': true,
  },
  {
    'name': 'config',
    'description': 'Set a setting by key',
    'argumentHint': 'key=value',
    'aliases': ['settings'],
    'builtin': true,
  },
  {
    'name': 'context',
    'description': 'Show current context usage',
    'argumentHint': '',
    'builtin': true,
  },
  {
    'name': 'model',
    'description': 'Set the AI model for Claude Code',
    'argumentHint': '<model>',
    'builtin': true,
  },
  {
    'name': 'code-review',
    'description': 'Review the current diff, or a PR number/branch/path target',
    'argumentHint': '[low|medium|high|xhigh|max] [--fix]',
    'aliases': ['review'],
    'builtin': true,
  },
  {
    'name': 'humanizer',
    'description':
        'Rewrite AI-sounding text so it reads like the writer.\n'
        'Use when editing',
    'argumentHint': '',
  },
  {
    'name': 'ponytail:ponytail',
    'description': '(ponytail) Forces the laziest solution that works',
    'argumentHint': '[lite|full|ultra]',
    'aliases': ['ponytail'],
  },
  {'name': 'deploy', 'description': 'Ship it', 'argumentHint': '<env>'},
];

String _output({List<Object?> rows = _rows, String yours = ''}) =>
    '${jsonEncode({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': 'sshbox-commands',
        'response': {'commands': rows},
      },
    })}\n${SlashCommand.yoursMark}$yours';

void main() {
  group('the listing', () {
    test('groups each command by where it comes from', () {
      final all = SlashCommand.parse(
        _output(yours: '/home/me/.claude/commands/deploy.md\n'),
      )!;
      SlashGroup group(String name) =>
          all.firstWhere((c) => c.name == name).group;
      expect(group('compact'), SlashGroup.builtIn);
      expect(group('humanizer'), SlashGroup.skills);
      expect(group('ponytail:ponytail'), SlashGroup.plugins);
      expect(group('deploy'), SlashGroup.yours);
      // A description's line breaks go: a row is one line.
      expect(
        all.firstWhere((c) => c.name == 'humanizer').description,
        'Rewrite AI-sounding text so it reads like the writer. Use when editing',
      );
      expect(all.firstWhere((c) => c.name == 'code-review').aliases, [
        'review',
      ]);
    });

    test('a name holding a space or a control character is left out, and '
        'control characters leave what is shown', () {
      final all = SlashCommand.parse(
        _output(
          rows: [
            {'name': 'two words', 'description': 'x'},
            {'name': 'evil\nrm -rf ~', 'description': 'x'},
            {'name': 'bell\x07', 'description': 'x'},
            {'name': 'fine', 'description': 'a\x1b[31mred\x1b[0m line'},
          ],
        ),
      )!;
      expect([for (final c in all) c.name], ['fine']);
      expect(all.single.description, isNot(contains('\x1b')));
    });

    test('hooks and other lines beside the answer do not cost it, and no '
        'answer is null', () {
      final output =
          'warning: something\n{"type":"system","subtype":"hook_response"}\n'
          '${_output()}';
      expect(SlashCommand.parse(output), hasLength(_rows.length));
      expect(
        SlashCommand.parse('Claude Code is not installed on this host'),
        isNull,
      );
    });

    test('the command runs through a real shell in a directory holding '
        'anything, and hands the stand-in claude its request', () async {
      final root = await Directory.systemTemp.createTemp('slash-commands');
      addTearDown(() => root.delete(recursive: true));
      final bin = await Directory('${root.path}/bin').create();
      // A stand-in that answers with what it was sent and where it ran.
      File('${bin.path}/claude').writeAsStringSync(
        '#!/bin/sh\n'
        'read -r line\n'
        'printf "{\\"type\\":\\"system\\"}\\n"\n'
        'printf \'%s\\n\' \'${jsonEncode({
          'type': 'control_response',
          'response': {
            'response': {
              'commands': [
                {'name': 'here', 'description': 'PWD'},
              ],
            },
          },
        })}\' | sed "s|PWD|\$(pwd)|; s|here|\$(echo "\$line" | grep -c initialize)ok|"\n',
      );
      await Process.run('chmod', ['+x', '${bin.path}/claude']);
      final home = await Directory('${root.path}/home').create();
      await Directory('${home.path}/.claude/commands').create(recursive: true);
      File('${home.path}/.claude/commands/mine.md').writeAsStringSync('x');

      for (final name in ['my dir', "it's here", r'$(touch RAN)', 'a;b']) {
        final dir = await Directory('${root.path}/$name').create();
        final result = await Process.run(
          'sh',
          ['-c', ClaudeChat.slashCommandsCommand(cwd: dir.path)],
          environment: {'PATH': '${bin.path}:/usr/bin:/bin', 'HOME': home.path},
          workingDirectory: root.path,
        );
        final all = SlashCommand.parse(result.stdout as String);
        expect(all, isNotNull, reason: '${result.stdout}${result.stderr}');
        expect(all!.single.name, '1ok', reason: 'sent initialize, "$name"');
        expect(all.single.description, dir.path, reason: name);
        expect(result.stdout, contains('/commands/mine.md'), reason: name);
      }
      expect(File('${root.path}/RAN').existsSync(), isFalse);
    });
  });

  group('what chat offers', () {
    final all = SlashCommand.parse(_output())!;

    test('a built-in that opens a dialog is not offered; prompts are', () {
      final offered = [for (final c in SlashCommand.matching(all, '')) c.name];
      expect(offered, containsAll(['compact', 'context', 'code-review']));
      expect(offered, containsAll(['humanizer', 'ponytail:ponytail']));
      expect(offered, isNot(contains('model')));
      expect(offered, isNot(contains('config')));
    });

    test('narrowing puts names that start with it before names holding it, '
        'and matches aliases', () {
      expect(
        [for (final c in SlashCommand.matching(all, 'co')) c.name],
        ['compact', 'context', 'code-review'],
      );
      expect(
        [for (final c in SlashCommand.matching(all, 'rev')) c.name],
        ['code-review'],
      );
      expect(
        [for (final c in SlashCommand.matching(all, 'tail')) c.name],
        ['ponytail:ponytail'],
      );
    });

    test('sending a dialog command, or one the host does not list, is '
        'refused; a path or a prompt is not', () {
      expect(SlashCommand.refusal('/model', all), contains('terminal'));
      expect(SlashCommand.refusal('/settings', all), isNotNull);
      expect(SlashCommand.refusal('  /config theme=dark', all), isNotNull);
      // Terminal-only, never listed to a pipe: /permissions, /rewind.
      expect(SlashCommand.refusal('/permissions', all), isNotNull);
      expect(SlashCommand.refusal('/compact keep the plan', all), isNull);
      expect(SlashCommand.refusal('/review', all), isNull);
      expect(SlashCommand.refusal('/humanizer', all), isNull);
      expect(SlashCommand.refusal('/tmp/x is full', all), isNull);
      expect(SlashCommand.refusal('what does /model do?', all), isNull);
      // Before the list is read, only built-ins known to run go.
      expect(SlashCommand.refusal('/compact', null), isNull);
      expect(SlashCommand.refusal('/humanizer', null), isNotNull);
    });
  });

  group('the transcript', () {
    test('a command line and what it printed read as such', () {
      final line =
          '<command-name>/color</command-name>\n'
          '            <command-message>color</command-message>\n'
          '            <command-args>cyan</command-args>';
      expect(CommandTags.command(line), (name: 'color', args: 'cyan'));
      expect(CommandTags.command('hello'), isNull);
      expect(
        CommandTags.output(
          '<local-command-stdout>\x1b[1mSet\x1b[22m</local-command-stdout>',
        ),
        'Set',
      );
      expect(CommandTags.output('<command-name>/x</command-name>'), isNull);
    });
  });

  group('the list', () {
    final all = SlashCommand.parse(_output())!;

    Future<TextEditingController> pump(
      WidgetTester tester, {
      AsyncSnapshot<List<SlashCommand>>? commands,
    }) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SlashCommandMenu(
                controller: controller,
                commands:
                    commands ??
                    AsyncSnapshot.withData(ConnectionState.done, all),
                child: TextField(controller: controller, autofocus: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('opens at a / under headings, and narrows as it is typed', (
      tester,
    ) async {
      final controller = await pump(tester);
      expect(find.text('/compact'), findsNothing);

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(find.text('BUILT-IN'), findsOneWidget);
      expect(find.text('SKILLS'), findsOneWidget);
      expect(find.text('/compact'), findsOneWidget);
      expect(find.text('Show current context usage'), findsOneWidget);
      expect(find.text('/model'), findsNothing);

      await tester.enterText(find.byType(TextField), '/hum');
      await tester.pump();
      expect(find.text('/humanizer'), findsOneWidget);
      expect(find.text('/compact'), findsNothing);
      expect(find.text('BUILT-IN'), findsNothing);

      // A space ends the name, and the list with it.
      await tester.enterText(find.byType(TextField), '/humanizer this');
      await tester.pump();
      expect(find.text('/humanizer'), findsNothing);
      expect(controller.text, '/humanizer this');
    });

    testWidgets('the arrows move, Enter and Tab pick, Escape closes', (
      tester,
    ) async {
      final controller = await pump(tester);
      await tester.enterText(find.byType(TextField), '/co');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.text, '/context ');
      expect(find.text('/compact'), findsNothing);

      await tester.enterText(find.byType(TextField), '/co');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text, '/code-review ');

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('/compact'), findsNothing);
      expect(controller.text, '/');
      // Typing on keeps it shut; emptying the box of its / opens it again.
      await tester.enterText(find.byType(TextField), '/c');
      await tester.pump();
      expect(find.text('/compact'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '/c');
      await tester.pump();
      expect(find.text('/compact'), findsOneWidget);
    });

    testWidgets('a tap picks', (tester) async {
      final controller = await pump(tester);
      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      await tester.tap(find.text('/humanizer'));
      await tester.pump();
      expect(controller.text, '/humanizer ');
      expect(find.text('/compact'), findsNothing);
    });

    testWidgets('says when the commands are being read or could not be', (
      tester,
    ) async {
      await pump(tester, commands: const AsyncSnapshot.waiting());
      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(find.text('Reading the commands on the host…'), findsOneWidget);

      await pump(
        tester,
        commands: const AsyncSnapshot.withError(
          ConnectionState.done,
          'claude: not found',
        ),
      );
      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(
        find.text('Could not read the commands: claude: not found'),
        findsOneWidget,
      );
    });
  });
}
