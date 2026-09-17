import 'dart:io';

import 'package:agent_cli/usage.dart';
import 'package:test/test.dart';

/// The `rate_limits` block of a Codex rollout, in both schema generations.
///
/// **Where the shapes come from.** [oldSchema] is the record already pinned by
/// `karmashala_agent_reporting/test/codex_rollout_classification_test.dart`
/// (2025-10, `resets_in_seconds`). [newSchema] carries the key set of a record
/// dated 2026-07-20 in a real store — `resets_at` in epoch seconds plus seven
/// more keys — with the numbers changed. Across that store's 29,390 blocks
/// `rate_limit_reached_type` was always null: **a non-null value has never
/// been observed**, so [reached]'s `"primary"` is a stand-in and only its
/// presence is read.
void main() {
  const oldSchema =
      '{"timestamp":"2025-10-16T10:21:41.993Z","type":"event_msg","payload":'
      '{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,'
      '"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,'
      '"total_tokens":272000},"last_token_usage":{"input_tokens":0,'
      '"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,'
      '"total_tokens":0},"model_context_window":272000},"rate_limits":'
      '{"primary":{"used_percent":0.0,"window_minutes":299,'
      '"resets_in_seconds":17903},"secondary":{"used_percent":40.0,'
      '"window_minutes":10079,"resets_in_seconds":159762}}}}';

  String newSchema({
    double primary = 51.0,
    String reachedType = 'null',
    String secondary = 'null',
  }) =>
      '{"timestamp":"2026-07-20T03:25:02.034Z","type":"event_msg","payload":'
      '{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,'
      '"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,'
      '"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":'
      '{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,'
      '"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},'
      '"model_context_window":258400},"rate_limits":{"limit_id":"codex",'
      '"limit_name":null,"primary":{"used_percent":$primary,'
      '"window_minutes":10080,"resets_at":1785021087},"secondary":$secondary,'
      '"credits":{"has_credits":false,"unlimited":false,"balance":"0"},'
      '"individual_limit":null,"spend_control_reached":null,'
      '"plan_type":"plus","rate_limit_reached_type":$reachedType}}}';

  const agentMessage =
      '{"timestamp":"2026-07-20T03:25:03.000Z","type":"event_msg","payload":'
      '{"type":"agent_message","message":"done"}}';

  test('the older schema: a reset is seconds from the record\'s own time', () {
    final snapshot = parseCodexRateLimitTail(oldSchema)!;
    expect(snapshot.windows.map((w) => w.label), ['5-hour', '7-day']);
    expect(snapshot.windows.first.span, kUsageFiveHourWindow);
    expect(
      snapshot.windows.first.resetsAt,
      DateTime.utc(2025, 10, 16, 10, 21, 41, 993).add(
        const Duration(seconds: 17903),
      ),
    );
    expect(snapshot.windows.last.percent, 40.0);
    expect(snapshot.limitReached, isFalse);
  });

  test('the current schema: `resets_at` is epoch seconds, a weekly primary is '
      'labelled by its period, and a null secondary is no window', () {
    final snapshot = parseCodexRateLimitTail(newSchema())!;
    final only = snapshot.windows.single;
    expect(only.label, '7-day');
    expect(only.percent, 51.0);
    expect(
      only.resetsAt,
      DateTime.fromMillisecondsSinceEpoch(1785021087 * 1000, isUtc: true),
    );
    expect(snapshot.reachedType, isNull);
    expect(snapshot.limitReached, isFalse);
    expect(snapshot.recordedAt, DateTime.utc(2026, 7, 20, 3, 25, 2, 34));
  });

  test('a window at its ceiling is a limit reached, and is the one blocking',
      () {
    final snapshot = parseCodexRateLimitTail(
      newSchema(
        primary: 100.0,
        secondary:
            '{"used_percent":12.0,"window_minutes":300,"resets_at":1785000000}',
      ),
    )!;
    expect(snapshot.limitReached, isTrue);
    expect(snapshot.blocking?.label, '7-day');
  });

  test('Codex naming the limit is one too, whatever the percentages say', () {
    final reached = parseCodexRateLimitTail(
      newSchema(primary: 99.0, reachedType: '"primary"'),
    )!;
    expect(reached.reachedType, 'primary');
    expect(reached.limitReached, isTrue);
  });

  test('the newest block wins, past records that carry none', () {
    final tail = [
      newSchema(primary: 100.0),
      newSchema(primary: 3.0),
      agentMessage,
    ].join('\n');
    expect(parseCodexRateLimitTail(tail)!.windows.single.percent, 3.0);
  });

  test('a first line cut by the tail window is skipped, not fatal', () {
    final cut = newSchema(primary: 100.0).substring(40);
    final tail = '$cut\n${newSchema(primary: 7.0)}';
    expect(parseCodexRateLimitTail(tail)!.windows.single.percent, 7.0);
  });

  test('a rollout with no block, or no rollout, reads as nothing', () async {
    expect(parseCodexRateLimitTail(agentMessage), isNull);
    expect(await readCodexRateLimits('/no/such/rollout.jsonl'), isNull);
  });

  test('only the tail of a large rollout is read', () async {
    final directory = await Directory.systemTemp.createTemp('codex-limits');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/rollout.jsonl');
    final padding = List.filled(800, agentMessage).join('\n');
    await file.writeAsString(
      '${newSchema(primary: 100.0)}\n$padding\n${newSchema(primary: 9.0)}\n',
    );
    expect(await file.length(), greaterThan(kCodexRateLimitTailBytes));
    final snapshot = await readCodexRateLimits(file.path);
    expect(snapshot!.windows.single.percent, 9.0);
  });
}
