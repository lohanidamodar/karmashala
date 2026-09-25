import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:agent_cli/src/agents/claude_code/claude_store_reader.dart';
import 'package:agent_cli/src/cli_detection/domain/session_stats.dart';
import 'package:path/path.dart' as p;

import '../support/temp_directory.dart';

/// Session stats read out of Claude Code's own JSONL store.
///
/// Two claims are under test here. The counts have to be right — Claude Code
/// writes one API response as several records and records tool results as
/// `user` turns, both of which inflate a naive tally — and reading them twice
/// has to cost nothing, because they are accumulated inside the store scan that
/// was already reading the file rather than by a second pass over it.
void main() {
  late Directory tmp;
  late String home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_stats');
    Directory(
      p.join(tmp.path, '.claude', 'projects', '-repo'),
    ).createSync(recursive: true);
    home = p.join(tmp.path, '.claude');
  });

  tearDown(() => removeTempDirectory(tmp));

  String pathFor(String id) => p.join(home, 'projects', '-repo', '$id.jsonl');

  String line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

  Map<String, Object?> user(String text, {String? at}) => {
    'type': 'user',
    'cwd': '/repo',
    'timestamp': at,
    'message': {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };

  Map<String, Object?> toolResult({String? at}) => {
    'type': 'user',
    'cwd': '/repo',
    'timestamp': at,
    'message': {
      'role': 'user',
      'content': [
        {'type': 'tool_result', 'tool_use_id': 'tu_1', 'content': 'ok'},
      ],
    },
  };

  /// One JSONL record for one content block of one API response. Claude Code
  /// writes several of these per response, each repeating the whole `usage`.
  Map<String, Object?> assistantBlock(
    String messageId,
    Map<String, Object?> block, {
    String? at,
    int input = 5,
    int output = 100,
    int cacheCreated = 20,
    int cacheRead = 300,
    String? model,
  }) => {
    'type': 'assistant',
    'timestamp': at,
    'requestId': 'req_$messageId',
    'message': {
      'id': messageId,
      'role': 'assistant',
      'model': ?model,
      'content': [block],
      'usage': {
        'input_tokens': input,
        'output_tokens': output,
        'cache_creation_input_tokens': cacheCreated,
        'cache_read_input_tokens': cacheRead,
      },
    },
  };

  void write(String id, List<Map<String, Object?>> records) =>
      File(pathFor(id)).writeAsStringSync(records.map(line).join());

  test('it counts prompts, replies, tool calls and tokens', () async {
    write('s1', [
      user('do the thing', at: '2026-01-01T00:00:00.000Z'),
      assistantBlock('msg_a', {'type': 'thinking', 'thinking': 'hmm'}),
      assistantBlock('msg_a', {'type': 'text', 'text': 'sure'}),
      assistantBlock('msg_a', {
        'type': 'tool_use',
        'id': 'tu_1',
        'name': 'Read',
      }),
      toolResult(),
      assistantBlock(
        'msg_b',
        {'type': 'text', 'text': 'done'},
        at: '2026-01-01T00:05:00.000Z',
        output: 50,
      ),
    ]);

    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    final stats = await reader.readSessionStats(pathFor('s1'));

    expect(stats, isNotNull);
    expect(stats!.source, SessionStatsSource.localStore);
    expect(stats.turns, 1, reason: 'the tool result is not a prompt');
    expect(stats.replies, 2, reason: 'three records, two API responses');
    expect(stats.toolCalls, 1);
    expect(stats.span, const Duration(minutes: 5));
  });

  test('a response split across records is charged once', () async {
    write('s1', [
      user('go'),
      assistantBlock('msg_a', {'type': 'thinking', 'thinking': 'hmm'}),
      assistantBlock('msg_a', {'type': 'text', 'text': 'sure'}),
      assistantBlock('msg_a', {
        'type': 'tool_use',
        'id': 'tu_1',
        'name': 'Read',
      }),
    ]);

    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    final stats = (await reader.readSessionStats(pathFor('s1')))!;

    // One `usage` block, not three: 5 / 100 / 20 / 300.
    expect(stats.tokens.input, 5);
    expect(stats.tokens.output, 100);
    expect(stats.tokens.cacheCreated, 20);
    expect(stats.tokens.cacheRead, 300);
    expect(stats.tokens.total, 425);
    // …but the tool call in the third record still counts, because each record
    // holds a *different* block.
    expect(stats.toolCalls, 1);
  });

  test(
    'it splits tokens by model, calls by tool, and output by turn',
    () async {
      write('s1', [
        user('plan it'),
        assistantBlock(
          'msg_a',
          {'type': 'tool_use', 'id': 'tu_1', 'name': 'Read'},
          model: 'claude-opus-4-1',
          output: 40,
        ),
        assistantBlock(
          'msg_a',
          {'type': 'tool_use', 'id': 'tu_2', 'name': 'Read'},
          model: 'claude-opus-4-1',
          output: 40,
        ),
        toolResult(),
        assistantBlock(
          'msg_b',
          {'type': 'tool_use', 'id': 'tu_3', 'name': 'Bash'},
          model: 'claude-haiku-4-5',
          input: 7,
          output: 9,
          cacheRead: 11,
        ),
        toolResult(),
        user('now build it'),
        assistantBlock(
          'msg_c',
          {'type': 'text', 'text': 'done'},
          model: 'claude-opus-4-1',
          input: 1,
          output: 60,
          cacheCreated: 2,
          cacheRead: 900,
        ),
        // Claude Code's own stand-in for a failed call: not a model.
        assistantBlock(
          'msg_d',
          {'type': 'text', 'text': 'API Error'},
          model: '<synthetic>',
          input: 0,
          output: 0,
          cacheCreated: 0,
          cacheRead: 0,
        ),
      ]);

      final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
      final stats = (await reader.readSessionStats(pathFor('s1')))!;

      expect(stats.toolCallsByName, {'Read': 2, 'Bash': 1});
      expect(stats.tokensByModel!.keys, {
        'claude-opus-4-1',
        'claude-haiku-4-5',
      });
      expect(
        stats.tokensByModel!['claude-opus-4-1'],
        const TokenTally(
          input: 6,
          output: 100,
          cacheCreated: 22,
          cacheRead: 1200,
        ),
        reason: 'msg_a once, not twice, plus msg_c',
      );
      expect(
        stats.tokensByModel!['claude-haiku-4-5'],
        const TokenTally(input: 7, output: 9, cacheCreated: 20, cacheRead: 11),
      );
      expect(stats.outputTokensPerTurn, [49, 60]);
      expect(
        stats.lastPromptTokens,
        0,
        reason: 'the newest call recorded is the synthetic one, and it sent 0',
      );
    },
  );

  test('the newest call\'s prompt is fresh input plus both caches', () async {
    write('s1', [
      user('go'),
      assistantBlock('msg_a', {'type': 'text', 'text': 'a'}),
      assistantBlock(
        'msg_b',
        {'type': 'text', 'text': 'b'},
        input: 3,
        cacheCreated: 40,
        cacheRead: 5000,
      ),
    ]);

    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    final stats = (await reader.readSessionStats(pathFor('s1')))!;

    expect(stats.lastPromptTokens, 5043);
    expect(
      stats.contextWindow,
      isNull,
      reason: 'Claude Code does not write it',
    );
  });

  test('tokens are unknown, not zero, when nothing recorded them', () async {
    write('s1', [
      user('go'),
      {
        'type': 'assistant',
        'message': {
          'id': 'msg_a',
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
        },
      },
    ]);

    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    final stats = (await reader.readSessionStats(pathFor('s1')))!;

    expect(stats.tokens.isUnknown, isTrue);
    expect(stats.tokens.total, isNull);
    expect(stats.replies, 1);
    expect(stats.tokensByModel, isNull);
    expect(stats.outputTokensPerTurn, isNull);
    expect(stats.lastPromptTokens, isNull);
  });

  test('a delegated agent\'s records are not this session\'s turns', () async {
    write('s1', [
      user('go'),
      {...user('sub-prompt'), 'isSidechain': true},
      {
        ...assistantBlock('msg_side', {'type': 'text', 'text': 'x'}),
        'isSidechain': true,
      },
    ]);

    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    final stats = (await reader.readSessionStats(pathFor('s1')))!;

    expect(stats.turns, 1);
    expect(stats.replies, 0);
    expect(stats.tokens.isUnknown, isTrue);
  });

  test('a missing file has no stats at all', () async {
    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    expect(await reader.readSessionStats(pathFor('nope')), isNull);
    expect(reader.bytesRead, 0);
  });

  group('cost', () {
    /// Enough bulk that re-reading it would be unmistakable in [bytesRead].
    void writeBulky(String id, {int turns = 200}) => write('s1', [
      user('start'),
      for (var i = 0; i < turns; i++) ...[
        assistantBlock('msg_$i', {
          'type': 'text',
          'text': 'a reasonably long reply so the file has some weight $i',
        }),
        assistantBlock('msg_$i', {
          'type': 'tool_use',
          'id': 'tu_$i',
          'name': 'Read',
        }),
        toolResult(),
        user('next $i'),
      ],
    ]);

    test('computing a session\'s stats twice reads nothing again', () async {
      writeBulky('s1');
      final reader = ClaudeStoreReader(cache: ClaudeStoreCache());

      final first = await reader.readSessionStats(pathFor('s1'));
      expect(first, isNotNull);
      expect(reader.bytesRead, greaterThan(0), reason: 'the first read reads');
      final afterFirst = reader.bytesRead;

      final second = await reader.readSessionStats(pathFor('s1'));

      expect(
        reader.bytesRead - afterFirst,
        0,
        reason: 'nothing moved, so a stat is the whole of the second read',
      );
      expect(second!.turns, first!.turns);
      expect(second.replies, first.replies);
      expect(second.toolCalls, first.toolCalls);
      expect(second.tokens.total, first.tokens.total);
    });

    test('and the store scan has already paid for the first', () async {
      writeBulky('s1');
      final reader = ClaudeStoreReader(cache: ClaudeStoreCache());

      await reader.read(home, 'windows');
      final afterScan = reader.bytesRead;
      expect(afterScan, greaterThan(0));

      final stats = await reader.readSessionStats(pathFor('s1'));

      expect(
        reader.bytesRead - afterScan,
        0,
        reason: 'the counts were accumulated by the scan, not by a second pass',
      );
      expect(stats!.turns, greaterThan(1));
    });

    test('a grown session resumes its counts from the last read', () async {
      writeBulky('s1');
      final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
      final before = (await reader.readSessionStats(pathFor('s1')))!;
      final sizeBefore = File(pathFor('s1')).lengthSync();
      final afterFirst = reader.bytesRead;

      File(pathFor('s1')).writeAsStringSync(
        [
          line(user('one more thing')),
          line(assistantBlock('msg_new', {'type': 'text', 'text': 'ok'})),
        ].join(),
        mode: FileMode.append,
      );
      final added = File(pathFor('s1')).lengthSync() - sizeBefore;

      final after = (await reader.readSessionStats(pathFor('s1')))!;

      expect(
        reader.bytesRead - afterFirst,
        lessThanOrEqualTo(added),
        reason: 'only the appended records, not the whole $sizeBefore bytes',
      );
      expect(after.turns, before.turns! + 1);
      expect(after.replies, before.replies! + 1);
      expect(after.tokens.output, before.tokens.output! + 100);
      expect(after.outputTokensPerTurn, [...before.outputTokensPerTurn!, 100]);
      expect(after.toolCallsByName, before.toolCallsByName);
    });

    test('a session rewritten from the top starts its counts over', () async {
      writeBulky('s1');
      final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
      final before = (await reader.readSessionStats(pathFor('s1')))!;
      expect(before.turns, greaterThan(1));

      write('s1', [user('fresh')]);

      final after = (await reader.readSessionStats(pathFor('s1')))!;
      expect(after.turns, 1);
      expect(after.replies, 0);
    });
  });
}
