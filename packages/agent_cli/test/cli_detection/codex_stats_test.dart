import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:agent_cli/src/agents/codex/codex_stats_reader.dart';
import 'package:agent_cli/src/cli_detection/domain/session_stats.dart';
import 'package:path/path.dart' as p;

import '../support/temp_directory.dart';

/// Session stats read out of a Codex rollout.
///
/// Codex's `token_count` records are **cumulative**, which is what makes both
/// of this reader's tricks legal: a resumed read gives the same answer a full
/// one would, and a cold read can find the whole token answer by scanning
/// backwards from EOF instead of decoding the file.
///
/// The cost group is the point of the design. A rollout is big because a
/// handful of pasted-context lines are enormous — 22 MB, in the owner's
/// largest — and the usage records in it are a thousandth of its size. So the
/// claim under test is not "it is fast" but "it does not decode what it does
/// not need", counted in lines.
void main() {
  late Directory tmp;

  setUp(
    () => tmp = Directory.systemTemp.createTempSync('karmashala_codex_stats'),
  );
  tearDown(() => removeTempDirectory(tmp));

  String rollout(String id) => p.join(tmp.path, 'rollout-$id.jsonl');

  String line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

  Map<String, Object?> meta({String cwd = '/repo'}) => {
    'timestamp': '2026-01-01T00:00:00.000Z',
    'type': 'session_meta',
    'payload': {'type': 'session_meta', 'id': 'abc', 'cwd': cwd},
  };

  Map<String, Object?> userMessage({String? at}) => {
    'timestamp': at,
    'type': 'event_msg',
    'payload': {'type': 'user_message', 'message': 'go'},
  };

  Map<String, Object?> agentMessage({String? at}) => {
    'timestamp': at,
    'type': 'event_msg',
    'payload': {'type': 'agent_message', 'message': 'done'},
  };

  Map<String, Object?> toolCall(String type, {String? name}) => {
    'type': 'response_item',
    'payload': {'type': type, 'name': ?name, 'call_id': 'c1'},
  };

  /// The cumulative usage record Codex writes after every model call.
  Map<String, Object?> tokenCount({
    required int input,
    required int cached,
    required int output,
    int cacheWrite = 0,
    int reasoning = 0,
    int contextWindow = 258400,
    int? lastInput,
    String? at,
  }) => {
    'timestamp': at,
    'type': 'event_msg',
    'payload': {
      'type': 'token_count',
      'info': {
        'total_token_usage': {
          'input_tokens': input,
          'cached_input_tokens': cached,
          'cache_write_input_tokens': cacheWrite,
          'output_tokens': output,
          'reasoning_output_tokens': reasoning,
          'total_tokens': input + output,
        },
        if (lastInput != null)
          'last_token_usage': {'input_tokens': lastInput, 'output_tokens': 1},
        'model_context_window': contextWindow,
      },
    },
  };

  void write(String id, List<Map<String, Object?>> records) =>
      File(rollout(id)).writeAsStringSync(records.map(line).join());

  test('it counts turns, tool calls and the newest cumulative usage', () async {
    write('r1', [
      meta(),
      userMessage(at: '2026-01-01T00:00:10.000Z'),
      toolCall('function_call'),
      toolCall('custom_tool_call'),
      toolCall('local_shell_call'),
      tokenCount(input: 100, cached: 40, output: 10),
      agentMessage(),
      userMessage(),
      // The later record supersedes the earlier one — it is not added to it.
      tokenCount(
        input: 900,
        cached: 400,
        output: 90,
        reasoning: 30,
        at: '2026-01-01T00:20:10.000Z',
      ),
      agentMessage(),
    ]);

    final reader = CodexStatsReader(cache: CodexStatsCache());
    final stats = await reader.readSessionStats(rollout('r1'));

    expect(stats, isNotNull);
    expect(stats!.source, SessionStatsSource.localStore);
    expect(stats.turns, 2);
    expect(stats.replies, 2);
    expect(stats.toolCalls, 3);
    expect(stats.tokens.input, 500, reason: '900 sent, 400 of it from cache');
    expect(stats.tokens.cacheRead, 400);
    expect(stats.tokens.output, 90);
    expect(stats.tokens.reasoning, 30);
    expect(
      stats.tokens.total,
      990,
      reason:
          '500 fresh + 400 cached + 90 out; reasoning is inside output, '
          'not a fifth bucket',
    );
    expect(stats.contextWindow, 258400);
    // From the `session_meta` line at 00:00:00 to the last record, not from
    // the first prompt: the rollout's own first timestamp is when the CLI
    // opened the conversation.
    expect(stats.span, const Duration(minutes: 20, seconds: 10));
  });

  test('it names tool calls from the head and keeps the last prompt', () async {
    write('r1', [
      meta(),
      userMessage(),
      toolCall('function_call', name: 'shell'),
      toolCall('function_call', name: 'shell'),
      toolCall('custom_tool_call', name: 'apply_patch'),
      toolCall('local_shell_call'),
      // A name the record did not carry is not guessed.
      toolCall('function_call'),
      // A name past the classification window is not read, so not invented.
      {
        'type': 'response_item',
        'payload': {
          'type': 'function_call',
          'call_id': 'c' * 300,
          'name': 'too_far',
        },
      },
      tokenCount(input: 900, cached: 400, output: 90, lastInput: 700),
    ]);

    final reader = CodexStatsReader(cache: CodexStatsCache());
    final stats = (await reader.readSessionStats(rollout('r1')))!;

    expect(stats.toolCalls, 6);
    expect(stats.toolCallsByName, {
      'shell': 2,
      'apply_patch': 1,
      'local_shell': 1,
    });
    expect(stats.lastPromptTokens, 700);
    expect(stats.tokensByModel, isNull, reason: 'one running total, no split');
    expect(stats.outputTokensPerTurn, [90]);
  });

  test('output and reasoning per turn are each record\'s step', () async {
    // Cumulative totals: each turn's share is the difference between the
    // usage record that closed it and the one before.
    write('r1', [
      meta(),
      userMessage(),
      tokenCount(input: 100, cached: 0, output: 40, reasoning: 30),
      tokenCount(input: 200, cached: 0, output: 50, reasoning: 34),
      agentMessage(),
      userMessage(),
      tokenCount(input: 300, cached: 0, output: 110, reasoning: 34),
      agentMessage(),
    ]);

    final reader = CodexStatsReader(cache: CodexStatsCache());
    final stats = (await reader.readSessionStats(rollout('r1')))!;

    expect(stats.tokens.output, 110);
    expect(stats.tokens.reasoning, 34);
    expect(stats.outputTokensPerTurn, [50, 60]);
    expect(stats.reasoningTokensPerTurn, [34, 0]);
  });

  test('a turn with no usage record yet counts as zero so far', () async {
    write('r1', [
      meta(),
      userMessage(),
      tokenCount(input: 100, cached: 0, output: 40, reasoning: 30),
      userMessage(),
    ]);

    final reader = CodexStatsReader(cache: CodexStatsCache());
    final stats = (await reader.readSessionStats(rollout('r1')))!;

    expect(stats.outputTokensPerTurn, [40, 0]);
    expect(stats.reasoningTokensPerTurn, [30, 0]);
  });

  test('a rollout with no usage record reports no tokens', () async {
    write('r1', [meta(), userMessage()]);

    final reader = CodexStatsReader(cache: CodexStatsCache());
    final stats = (await reader.readSessionStats(rollout('r1')))!;

    expect(stats.tokens.isUnknown, isTrue);
    expect(stats.contextWindow, isNull);
    expect(stats.lastPromptTokens, isNull);
    expect(stats.turns, 1);
  });

  test('a missing rollout has no stats at all', () async {
    final reader = CodexStatsReader(cache: CodexStatsCache());
    expect(await reader.readSessionStats(rollout('nope')), isNull);
    expect(reader.bytesRead, 0);
  });

  group('cost', () {
    void writeBulky(String id, {int turns = 300}) => write(id, [
      meta(),
      for (var i = 0; i < turns; i++) ...[
        userMessage(),
        toolCall('function_call'),
        tokenCount(input: 100 * (i + 1), cached: 40 * i, output: 10 * (i + 1)),
        agentMessage(),
      ],
    ]);

    test('reading a rollout\'s stats twice reads nothing again', () async {
      writeBulky('r1');
      final reader = CodexStatsReader(cache: CodexStatsCache());

      final first = await reader.readSessionStats(rollout('r1'));
      expect(first, isNotNull);
      expect(reader.bytesRead, greaterThan(0), reason: 'the first read reads');
      final afterFirst = reader.bytesRead;

      final second = await reader.readSessionStats(rollout('r1'));

      expect(
        reader.bytesRead - afterFirst,
        0,
        reason: 'nothing moved, so a stat is the whole of the second read',
      );
      expect(second!.turns, first!.turns);
      expect(second.tokens.total, first.tokens.total);
    });

    test('a live rollout resumes from where the last read stopped', () async {
      writeBulky('r1');
      final reader = CodexStatsReader(cache: CodexStatsCache());
      final before = (await reader.readSessionStats(rollout('r1')))!;
      final sizeBefore = File(rollout('r1')).lengthSync();
      final afterFirst = reader.bytesRead;

      File(rollout('r1')).writeAsStringSync(
        [
          line(userMessage()),
          line(toolCall('function_call', name: 'late_tool')),
          line(
            tokenCount(
              input: 99999,
              cached: 0,
              output: before.tokens.output! + 5,
              lastInput: 77,
            ),
          ),
        ].join(),
        mode: FileMode.append,
      );
      final added = File(rollout('r1')).lengthSync() - sizeBefore;

      final after = (await reader.readSessionStats(rollout('r1')))!;

      expect(
        reader.bytesRead - afterFirst,
        lessThanOrEqualTo(added),
        reason: 'only the appended records, not the whole $sizeBefore bytes',
      );
      expect(after.turns, before.turns! + 1);
      expect(after.tokens.input, 99999);
      expect(after.lastPromptTokens, 77);
      expect(
        after.outputTokensPerTurn!.length,
        before.outputTokensPerTurn!.length + 1,
      );
      expect(
        after.outputTokensPerTurn!.last,
        5,
        reason: 'the step from the cached total, not from zero',
      );
      expect(after.toolCallsByName!['late_tool'], 1);
      expect(
        before.toolCallsByName!.containsKey('late_tool'),
        isFalse,
        reason: 'the cached counters were copied, not shared',
      );
    });

    test('a record still being written is not resumed inside', () async {
      write('r1', [meta(), userMessage()]);
      final reader = CodexStatsReader(cache: CodexStatsCache());
      expect((await reader.readSessionStats(rollout('r1')))!.turns, 1);

      // A half-written line: no newline yet, which is what a live CLI leaves
      // between flushes.
      File(
        rollout('r1'),
      ).writeAsStringSync('{"type":"event_msg","payl', mode: FileMode.append);
      expect((await reader.readSessionStats(rollout('r1')))!.turns, 1);

      File(rollout('r1')).writeAsStringSync(
        'oad":{"type":"user_message"}}\n',
        mode: FileMode.append,
      );
      expect((await reader.readSessionStats(rollout('r1')))!.turns, 2);
    });

    test('a huge pasted line is skipped, never decoded', () async {
      // The shape that made a naive reader cost 1.9 seconds: one 2 MB user
      // message, the sort a pasted IDE context block produces. The reader must
      // count it as a turn from its head and never build a String out of it.
      final huge = 'x' * (2 * 1024 * 1024);
      write('r1', [
        meta(),
        {
          'timestamp': '2026-01-01T00:00:10.000Z',
          'type': 'event_msg',
          'payload': {'type': 'user_message', 'message': huge},
        },
        toolCall('function_call'),
        {
          'timestamp': '2026-01-01T00:00:20.000Z',
          'type': 'response_item',
          'payload': {'type': 'message', 'role': 'user', 'content': huge},
        },
        tokenCount(input: 900, cached: 400, output: 90),
      ]);
      final size = File(rollout('r1')).lengthSync();
      expect(size, greaterThan(4 * 1024 * 1024));

      final reader = CodexStatsReader(cache: CodexStatsCache());
      final stats = (await reader.readSessionStats(rollout('r1')))!;

      expect(stats.turns, 1);
      expect(stats.toolCalls, 1);
      expect(stats.tokens.total, 990);
      expect(
        reader.linesDecoded,
        1,
        reason: 'the only line worth decoding is the usage record',
      );
    });

    test(
      'a cold read of a big rollout decodes only its usage records',
      () async {
        // Usage records are a thousandth of a rollout; per-turn tokens need
        // every one of them, and nothing else is ever decoded.
        write('r1', [
          meta(),
          for (var i = 0; i < 300; i++) ...[
            userMessage(),
            toolCall('custom_tool_call'),
            {
              'type': 'response_item',
              'payload': {
                'type': 'message',
                'role': 'user',
                'content': 'y' * 900,
              },
            },
            tokenCount(input: 100 * (i + 1), cached: 0, output: 1),
          ],
        ]);
        expect(File(rollout('r1')).lengthSync(), greaterThan(64 * 1024));

        final reader = CodexStatsReader(cache: CodexStatsCache());
        final stats = (await reader.readSessionStats(rollout('r1')))!;

        expect(stats.turns, 300);
        expect(stats.toolCalls, 300);
        expect(
          stats.tokens.input,
          30000,
          reason: 'the newest cumulative total',
        );
        expect(stats.outputTokensPerTurn!.length, 300);
        expect(reader.linesDecoded, 300);
      },
    );

    test('a rollout replaced under the same name starts over', () async {
      writeBulky('r1');
      final reader = CodexStatsReader(cache: CodexStatsCache());
      expect((await reader.readSessionStats(rollout('r1')))!.turns, 300);

      write('r1', [meta(), userMessage()]);

      expect((await reader.readSessionStats(rollout('r1')))!.turns, 1);
    });
  });
}
