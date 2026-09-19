@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// Which keys answer Claude Code's `AskUserQuestion` prompt — measured against
/// the real CLI in a real ConPTY, because the phone answers a question by
/// typing into the pane and a guessed key sequence answers the wrong option.
///
/// What an answer came to is read from the session's own transcript (the
/// `tool_result` Claude Code records), never from the screen.
///
/// Spends a small model turn per case, so it is excluded from the gate:
///
///   KARMASHALA_CLAUDE=C:\Users\me\.local\bin\claude.exe \
///     dart test --tags=live test/agents/claude_question_keys_live_test.dart
///
/// KARMASHALA_QUESTION_CWD must be a folder Claude Code already trusts, or the
/// trust dialog answers the first key instead.
void main() {
  final claude = Platform.environment['KARMASHALA_CLAUDE'];
  final cwd = Platform.environment['KARMASHALA_QUESTION_CWD'];
  final skip = !Platform.isWindows
      ? 'ConPTY is Windows only'
      : claude == null || cwd == null
      ? 'set KARMASHALA_CLAUDE and KARMASHALA_QUESTION_CWD'
      : false;

  const enter = '\r';

  /// One AskUserQuestion, answered by [keys]; returns what Claude recorded.
  Future<String> answer(String questions, List<String> keys) async {
    final session = _uuid();
    final pty = ConPtyLauncher().start(
      PtySpawnRequest(
        argv: [
          claude!,
          '--session-id',
          session,
          '--model',
          'haiku',
          '--permission-mode',
          'plan',
        ],
        workingDirectory: cwd!,
        environment: const {
          'TERM': 'xterm-256color',
          // Run from inside an agent, the child inherits a marker that turns
          // transcript saving off — and the transcript is what is read here.
          'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE': '1',
        },
        columns: 160,
        rows: 50,
      ),
    );
    addTearDown(pty.close);
    final screen = _Screen(pty.output, reply: (bytes) => pty.write(Uint8List.fromList(bytes)));

    await screen.until('❯', const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(seconds: 1));
    pty.write(
      utf8.encode(
        'Throwaway UI test. Call no tool except AskUserQuestion, exactly once, '
        'with these questions: $questions. After it returns, reply only OK.',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    pty.write(utf8.encode(enter));
    await screen.until('Enter to select', const Duration(seconds: 90));
    if (Platform.environment['KARMASHALA_SHOW_SCREEN'] == '1') {
      print('--- question drawn:\n${screen.tail(3000)}');
    }
    await Future<void>.delayed(const Duration(seconds: 1));

    for (final key in keys) {
      pty.write(utf8.encode(key));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (Platform.environment['KARMASHALA_SHOW_SCREEN'] == '1') {
        print('--- after ${jsonEncode(key)}:\n${screen.tail(1200)}');
      }
    }
    return _toolResult(cwd, session, const Duration(seconds: 30));
  }

  group('Claude Code AskUserQuestion keys', skip: skip, () {
    final support = AgentRegistry.builtIn.byId('claudeCode')!.questions!;

    Map<String, Object?> q(String question, List<String> options, {bool multi = false}) => {
      'question': question,
      'header': question.split(' ').last,
      'multiSelect': multi,
      'options': [for (final o in options) {'label': o, 'description': o}],
    };

    /// Asks [questions], answers them with the production key builder, and
    /// returns the `answers` map Claude Code recorded.
    Future<Map<String, Object?>> round(
      List<Map<String, Object?>> questions,
      List<AgentQuestionAnswer> answers,
    ) async {
      final set = AgentQuestionSet.fromToolInput('t', {'questions': questions})!;
      final keys = support.keysFor(set, answers);
      // One write per key, and an arrow's escape sequence travels whole, the
      // way a terminal sends it.
      final result = await answer(jsonEncode(questions), [
        for (final m in RegExp(r'\x1b\[[A-D]|[\s\S]').allMatches(keys)) m[0]!,
      ]);
      final recorded = jsonDecode(result.split(' | toolUseResult=').last);
      return ((recorded as Map)['answers'] as Map).cast<String, Object?>();
    }

    test('one option of one question', () async {
      expect(
        await round([q('Pick a fruit', ['Apple', 'Banana', 'Cherry'])], [
          const AgentQuestionAnswer.option(1),
        ]),
        {'Pick a fruit': 'Banana'},
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('own words', () async {
      expect(
        await round([q('Pick a fruit', ['Apple', 'Banana', 'Cherry'])], [
          const AgentQuestionAnswer.text('Durian'),
        ]),
        {'Pick a fruit': 'Durian'},
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('several boxes', () async {
      expect(
        await round([q('Pick colours', ['Red', 'Green', 'Blue'], multi: true)], [
          const AgentQuestionAnswer.options([0, 2]),
        ]),
        {'Pick colours': 'Red, Blue'},
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('two questions', () async {
      expect(
        await round(
          [
            q('Pick a size', ['Small', 'Large']),
            q('Pick a speed', ['Slow', 'Fast']),
          ],
          [
            const AgentQuestionAnswer.option(1),
            const AgentQuestionAnswer.option(1),
          ],
        ),
        {'Pick a size': 'Large', 'Pick a speed': 'Fast'},
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
String _uuid() {
  final r = Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// The `tool_result` answering the AskUserQuestion call in [session]'s
/// transcript, with the structured `toolUseResult` beside it.
Future<String> _toolResult(String cwd, String session, Duration within) async {
  final home = Platform.environment['USERPROFILE']!;
  final folder = cwd.replaceAll(RegExp(r'[:\\/.]'), '-');
  final file = File('$home\\.claude\\projects\\$folder\\$session.jsonl');
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (file.existsSync()) {
      String? askId;
      for (final line in file.readAsLinesSync()) {
        final record = jsonDecode(line);
        if (record is! Map) continue;
        final content = (record['message'] as Map?)?['content'];
        if (content is! List) continue;
        for (final block in content) {
          if (block is! Map) continue;
          if (block['type'] == 'tool_use' && block['name'] == 'AskUserQuestion') {
            askId = block['id'] as String?;
          }
          if (block['type'] == 'tool_result' && block['tool_use_id'] == askId) {
            return '${jsonEncode(block['content'])} '
                '| toolUseResult=${jsonEncode(record['toolUseResult'])}';
          }
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return 'NO RESULT in ${file.path}';
}

class _Screen {
  _Screen(Stream<List<int>> output, {required void Function(List<int>) reply}) {
    output.listen((chunk) {
      _bytes += chunk.length;
      final raw = utf8.decode(chunk, allowMalformed: true);
      // A terminal answers these; a TUI waits for the answer before drawing.
      if (raw.contains('\x1b[6n')) reply(utf8.encode('\x1b[1;1R'));
      if (raw.contains('\x1b[c') || raw.contains('\x1b[0c')) {
        reply(utf8.encode('\x1b[?62;22c'));
      }
      _text.write(
        raw
            .replaceAll(RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]'), '')
            .replaceAll(RegExp(r'\x1b\][^\x07]*\x07'), ''),
      );
    });
  }

  final _text = StringBuffer();
  var _bytes = 0;

  String tail(int n) {
    final s = _text.toString();
    return s.length <= n ? s : s.substring(s.length - n);
  }

  Future<void> until(String needle, Duration within) async {
    final deadline = DateTime.now().add(within);
    // Cursor moves stand in for spaces once the codes are stripped, so both
    // sides are compared without them.
    final want = needle.replaceAll(' ', '');
    while (!_text.toString().replaceAll(' ', '').contains(want)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('never saw "$needle" ($_bytes bytes seen):\n${tail(2000)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
