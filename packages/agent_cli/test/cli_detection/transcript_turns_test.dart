import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp_directory.dart';

const _roles = {'user', 'agent'};

String _user(String text) =>
    '${jsonEncode({
      'type': 'user',
      'timestamp': '2026-09-21T10:00:00Z',
      'message': {'role': 'user', 'content': text},
    })}\n';

String _agent(String text) =>
    '${jsonEncode({
      'type': 'assistant',
      'timestamp': '2026-09-21T10:00:01Z',
      'message': {
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    })}\n';

String _call(String id, String command, String output) =>
    '${jsonEncode({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': id,
            'name': 'Bash',
            'input': {'command': command},
          },
        ],
      },
    })}\n'
    '${jsonEncode({
      'type': 'user',
      'message': {
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': output},
        ],
      },
    })}\n';

/// **The search index's reader resumes from a stored point, and a resumed read
/// answers what a whole-file read of the same bytes would.**
///
/// Every case compares against [readCliTranscript] of the file as it stands —
/// the same oracle `cli_transcript_tail_test.dart` uses — and counts bytes, so
/// "only the appended bytes" is measured rather than assumed. Synthetic only.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('transcript_turns'));
  tearDown(() => removeTempDirectory(dir));

  File transcript(String content) =>
      File(p.join(dir.path, 'c.jsonl'))..writeAsStringSync(content);

  /// What a whole-file read says the searchable rows are, as the oracle.
  Future<List<(int, String, String)>> oracle(File file) async {
    final all = await readCliTranscript(file.path, AgentIds.claudeCode);
    return [
      for (final turn in transcriptTurnsOf(all, _roles))
        (turn.ordinal, turn.role, turn.text),
    ];
  }

  List<(int, String, String)> rows(List<IndexableTurn> turns) => [
    for (final turn in turns) (turn.ordinal, turn.role, turn.text),
  ];

  test('a first read is the whole file: visible turns only', () async {
    final file = transcript(
      _user('fix the stripe webhook') +
          _call('t1', 'grep -r webhook', 'lib/webhook.dart') +
          _agent('the signature check was wrong'),
    );

    final read = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
    );

    expect(read.appended, isFalse);
    expect(rows(read.turns), await oracle(file));
    expect(read.turns.map((t) => t.role), ['user', 'agent']);
    // The tool row sits between them and keeps its place in the numbering, so
    // an ordinal still lines up with the chat view.
    expect(read.turns.map((t) => t.ordinal), [0, 2]);
    expect(read.turns.first.at, DateTime.utc(2026, 9, 21, 10));
    expect(read.bytesRead, file.lengthSync());
    expect(read.resumePoint!.end, file.lengthSync());

    // A file past the caller's bound is parsed on a worker, to the same rows.
    final onWorker = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
      onCallerBytes: 0,
    );
    expect(rows(onWorker.turns), rows(read.turns));
    expect(onWorker.resumePoint!.end, read.resumePoint!.end);
  });

  test('a resumed read parses only what was appended', () async {
    final file = transcript(
      _user('first question') + _call('t1', 'ls', 'a\nb') + _agent('first'),
    );
    final first = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
    );
    final appended = _user('second question') + _agent('second answer');
    file.writeAsStringSync(appended, mode: FileMode.append);

    final next = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
      from: first.resumePoint,
    );

    expect(next.appended, isTrue);
    // The claim: the bytes gone through are the appended ones, not the file.
    expect(next.bytesRead, utf8.encode(appended).length);
    expect(next.bytesRead, lessThan(file.lengthSync()));
    // And the rows are exactly the ones a whole read has past the old point.
    final whole = await oracle(file);
    expect([...rows(first.turns), ...rows(next.turns)], whole);
    expect(rows(next.turns).map((r) => r.$3), [
      'second question',
      'second answer',
    ]);
  });

  test('the same answer when the append is parsed on a worker', () async {
    final file = transcript(_user('one'));
    final first = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
    );
    file.writeAsStringSync(
      _agent('two') + _user('three'),
      mode: FileMode.append,
    );

    final next = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
      from: first.resumePoint,
      onCallerBytes: 0,
    );

    expect(next.appended, isTrue);
    expect([...rows(first.turns), ...rows(next.turns)], await oracle(file));
  });

  test('a last record with no newline is read, but not resumed past', () async {
    final file = transcript(_user('complete'));
    final last = _agent('the last word');
    file.writeAsStringSync(
      last.substring(0, last.length - 1),
      mode: FileMode.append,
    );

    final first = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
    );
    // As a whole-file read reads it — a file may simply end without one.
    expect(rows(first.turns), await oracle(file));
    expect(first.turns.last.ordinal, first.resumePoint!.rows);
    expect(first.resumePoint!.end, lessThan(file.lengthSync()));

    file.writeAsStringSync('\n', mode: FileMode.append);
    final next = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
      from: first.resumePoint,
    );
    expect(next.appended, isTrue);
    // The same record again at the same ordinal, for the caller to replace.
    expect(rows(next.turns), [rows(first.turns).last]);
  });

  test('a record cut mid-write yields nothing until it is whole', () async {
    final file = transcript(_user('complete'));
    final last = _agent('half of this');
    file.writeAsStringSync(
      last.substring(0, last.length ~/ 2),
      mode: FileMode.append,
    );

    final first = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
    );
    expect(rows(first.turns).map((r) => r.$3), ['complete']);

    file.writeAsStringSync(
      last.substring(last.length ~/ 2),
      mode: FileMode.append,
    );
    final next = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
      from: first.resumePoint,
    );
    expect(rows(next.turns).map((r) => r.$3), ['half of this']);
  });

  test('a file that shrank is read whole again', () async {
    final file = transcript(_user('old one') + _user('old two'));
    final first = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
    );
    file.writeAsStringSync(_user('new'));

    final next = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
      from: first.resumePoint,
    );

    expect(next.appended, isFalse);
    expect(rows(next.turns), await oracle(file));
  });

  test('a file rewritten to the same length or longer is read whole', () async {
    // Longer than before, so only the identifying bytes can tell: a resume on
    // length alone would append the new file's tail to the old file's rows.
    final file = transcript(_user('alpha') + _user('beta'));
    final first = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
    );
    file.writeAsStringSync(_user('gamma') + _user('delta') + _user('epsilon'));

    final next = await readTranscriptTurns(
      file.path,
      AgentIds.claudeCode,
      roles: _roles,
      from: first.resumePoint,
    );

    expect(next.appended, isFalse);
    expect(rows(next.turns).map((r) => r.$3), ['gamma', 'delta', 'epsilon']);
  });

  test('a missing file answers nothing and no resume point', () async {
    final read = await readTranscriptTurns(
      p.join(dir.path, 'gone.jsonl'),
      AgentIds.claudeCode,
      roles: _roles,
    );
    expect(read.turns, isEmpty);
    expect(read.resumePoint, isNull);
  });

  // The property the design rests on: a visible turn never depends on a line
  // before it, so a fresh parse from any record boundary finds the same turns
  // at the same ordinals. Grown in random pieces, cut mid-record included.
  for (final (cli, fixture) in [
    (AgentIds.claudeCode, _claudeFixture),
    (AgentIds.codex, _codexFixture),
  ]) {
    test(
      '$cli: resumed reads add up to a whole read, over random splits',
      () async {
        final content = utf8.encode(fixture(Random(11)));
        final random = Random(cli.length);
        for (var round = 0; round < 10; round++) {
          final cuts = {
            for (var i = 0; i < 1 + random.nextInt(20); i++)
              random.nextInt(content.length),
          }.toList()..sort();
          final file = File(p.join(dir.path, '$cli-$round.jsonl'))
            ..writeAsBytesSync(const []);
          final collected = <(int, String, String)>[];
          TranscriptResumePoint? point;
          var at = 0;
          var resumed = 0;
          for (final cut in [...cuts, content.length]) {
            file.writeAsBytesSync(
              content.sublist(at, cut),
              mode: FileMode.append,
            );
            at = cut;
            final read = await readTranscriptTurns(
              file.path,
              cli,
              roles: _roles,
              from: point,
            );
            if (read.appended && point != null) {
              resumed++;
              // What the index does: replace from the resume point, so a last
              // record read before its newline landed is kept once.
              final from = point.rows;
              collected.removeWhere((r) => r.$1 >= from);
            } else {
              collected.clear();
            }
            collected.addAll(rows(read.turns));
            point = read.resumePoint;
            final now = await readCliTranscript(file.path, cli);
            expect(collected, [
              for (final t in transcriptTurnsOf(now, _roles))
                (t.ordinal, t.role, t.text),
            ], reason: '$cli after $cut bytes, cuts $cuts');
          }
          final whole = await readCliTranscript(file.path, cli);
          expect(collected, [
            for (final t in transcriptTurnsOf(whole, _roles))
              (t.ordinal, t.role, t.text),
          ], reason: '$cli cuts $cuts');
          // Guard against a false green: the pieces really were resumed.
          expect(resumed, cuts.length);
        }
      },
    );
  }
}

String _claudeFixture(Random r) {
  final out = StringBuffer();
  final open = <String>[];
  for (var i = 0; i < 200; i++) {
    switch (r.nextInt(7)) {
      case 0:
        out.write(_user('question $i — naïve café ✓'));
      case 1:
        out.write(_agent('answer $i about the webhook'));
      case 2:
        final id = 'toolu_$i';
        open.add(id);
        out.write(
          '${jsonEncode({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': 'running $i'},
                {
                  'type': 'tool_use',
                  'id': id,
                  'name': 'Bash',
                  'input': {'command': 'ls $i'},
                },
              ],
            },
          })}\n',
        );
      case 3:
        if (open.isEmpty) continue;
        final id = open.removeAt(r.nextInt(open.length));
        out.write(
          '${jsonEncode({
            'type': 'user',
            'message': {
              'content': [
                {'type': 'tool_result', 'tool_use_id': id, 'content': 'out ${'x' * r.nextInt(400)}'},
              ],
            },
          })}\n',
        );
      case 4:
        out.write(
          '${jsonEncode({
            'type': 'system',
            'subtype': 'compact_boundary',
            'compactMetadata': {'trigger': 'auto'},
          })}\n',
        );
      case 5:
        out.write(r.nextBool() ? '{"type":\n' : '\n');
      case _:
        out.write(_user('follow-up $i'));
    }
  }
  return out.toString();
}

String _codexFixture(Random r) {
  final out = StringBuffer();
  for (var i = 0; i < 200; i++) {
    final payload = switch (r.nextInt(4)) {
      0 => {
        'type': 'message',
        'role': r.nextBool() ? 'user' : 'assistant',
        'content': [
          {'type': 'output_text', 'text': 'codex $i ✓'},
        ],
      },
      1 => {
        'type': 'function_call',
        'name': 'shell',
        'call_id': 'call_$i',
        'arguments': jsonEncode({
          'command': ['echo', '$i'],
        }),
      },
      2 => {
        'type': 'function_call_output',
        'call_id': 'call_${i - 1}',
        'output': 'out $i',
      },
      _ => {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'prompt $i'},
        ],
      },
    };
    out.write(
      '${jsonEncode({'timestamp': '2026-09-21T10:00:00Z', 'type': 'response_item', 'payload': payload})}\n',
    );
  }
  return out.toString();
}
