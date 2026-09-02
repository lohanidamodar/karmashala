import 'dart:io';

import 'package:karmashala/src/features/agents/data/agent_state_file_status_source.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// What Karmashala can read off a Codex rollout.
///
/// Every record below is the shape the owner's own store writes
/// (`~/.codex/sessions`, 52 rollouts across 2025 and 2026, ~46,000 records),
/// trimmed to the fields that classify it and with the prose replaced. The
/// counts in `the population` are that store's census of **last** records.
///
/// The rules this exercises were rewritten because replaying the old ones over
/// those 52 files gave 39 `unknown`, 13 `idle` and — for a rule set three
/// quarters of which claims `working` — not one `working`.
void main() {
  const source = AgentStateFileStatusSource();
  final codex = AgentRegistry.builtIn.byId('codex')!;
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;

  late Directory tmp;
  var next = 0;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_codex_');
    next = 0;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(List<String> lines) {
    final file = File(p.join(tmp.path, 'rollout-${next++}.jsonl'))
      ..createSync(recursive: true);
    file.writeAsStringSync('${lines.join('\n')}\n');
    return file.path;
  }

  DateTime fresh(String path) =>
      File(path).statSync().modified.add(const Duration(seconds: 5));
  DateTime stale(String path) =>
      File(path).statSync().modified.add(const Duration(hours: 3));

  // ---------------------------------------------------------------- records

  /// The turn's closing bracket: `turn_id`, how long it took, and the last
  /// thing the agent said. 27 of the store's 52 files end on one of these, and
  /// every one of them used to read `unknown`.
  const taskComplete =
      '{"timestamp":"2026-02-28T08:21:18.321Z","type":"event_msg","payload":'
      '{"type":"task_complete","turn_id":"019ca351-b615-7fc0-9615-1a2919588b54"'
      ',"last_agent_message":"Third pass completed and applied.",'
      '"started_at":1785224288,"completed_at":1785224324,"duration_ms":35968,'
      '"time_to_first_token_ms":3336}}';

  /// The turn's opening bracket.
  const taskStarted =
      '{"timestamp":"2026-02-28T08:20:42.353Z","type":"event_msg","payload":'
      '{"type":"task_started","turn_id":"019ca351-b615-7fc0-9615-1a2919588b54",'
      '"started_at":1785224288}}';

  const assistantMessage =
      '{"timestamp":"2025-09-16T14:58:24.093Z","type":"response_item",'
      '"payload":{"type":"message","role":"assistant","content":'
      '[{"type":"output_text","text":"Done."}]}}';

  const userMessage =
      '{"timestamp":"2025-10-16T10:21:34.746Z","type":"response_item",'
      '"payload":{"type":"message","role":"user","content":'
      '[{"type":"input_text","text":"carry on"}]}}';

  /// The 2025 envelope, before rollouts wrapped every record in `payload`.
  const legacyAssistantMessage =
      '{"type":"message","id":"msg_68b30631045081a0a2b439775a917df4",'
      '"role":"assistant","content":[{"type":"output_text","text":"Yes."}]}';

  const turnAborted =
      '{"timestamp":"2025-10-09T14:53:22.317Z","type":"event_msg","payload":'
      '{"type":"turn_aborted","reason":"interrupted"}}';

  /// The most frequent record in the whole store — 9,650 of them — and the one
  /// that lands between every pair of records that classify.
  const tokenCount =
      '{"timestamp":"2025-10-16T10:21:41.993Z","type":"event_msg","payload":'
      '{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,'
      '"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,'
      '"total_tokens":272000},"last_token_usage":{"input_tokens":0,'
      '"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,'
      '"total_tokens":0},"model_context_window":272000},"rate_limits":'
      '{"primary":{"used_percent":0.0,"window_minutes":299,'
      '"resets_in_seconds":17903},"secondary":{"used_percent":40.0,'
      '"window_minutes":10079,"resets_in_seconds":159762}}}}';

  const turnContext =
      '{"timestamp":"2025-10-16T10:21:34.746Z","type":"turn_context","payload":'
      '{"cwd":"C:\\\\src\\\\demo","approval_policy":"on-request"}}';

  /// A 2025 header record. Two files end on one.
  const stateHeader = '{"record_type":"state"}';

  const customToolCallOutput =
      '{"timestamp":"2025-10-24T02:21:38.388Z","type":"response_item",'
      '"payload":{"type":"custom_tool_call_output","call_id":"call_1",'
      '"output":"ok"}}';

  const functionCall =
      '{"timestamp":"2026-02-28T08:20:44.000Z","type":"response_item",'
      '"payload":{"type":"function_call","name":"shell","call_id":"call_2",'
      '"arguments":"{}"}}';

  // ------------------------------------------------------------ one at a time

  group('the records that bracket a turn', () {
    test('task_complete is idle — the record that means "finished"', () async {
      final path = write([taskStarted, functionCall, taskComplete]);

      final report = (await source.read(codex, path, stale(path)))!;

      expect(report.status, AgentActivityStatus.idle);
      expect(report.detail, 'payload.type=task_complete');
    });

    test('task_started is working', () async {
      final path = write([taskComplete, userMessage, taskStarted]);

      final report = (await source.read(codex, path, fresh(path)))!;

      expect(report.status, AgentActivityStatus.working);
      expect(report.detail, 'payload.type=task_started');
    });

    test('an interrupted turn is an ending, not a failure', () async {
      // `TurnAbortReason` is `{Interrupted, Replaced, ReviewEnded,
      // BudgetLimited}` — no failure variant exists — and the user who pressed
      // Esc is already looking at the session.
      final path = write([taskStarted, turnAborted]);

      expect(
        (await source.read(codex, path, stale(path)))!.status,
        AgentActivityStatus.idle,
      );
    });

    test('the 2025 envelope still classifies', () async {
      final path = write([stateHeader, legacyAssistantMessage]);

      expect(
        (await source.read(codex, path, stale(path)))!.status,
        AgentActivityStatus.idle,
      );
    });
  });

  group('walking past bookkeeping', () {
    test('a token_count record no longer costs the answer', () async {
      // The live failure this fixes: a rate-limit record arrives after the turn
      // ends, and the session flips from "finished" to "we lost track".
      final path = write([taskComplete, tokenCount]);

      final report = (await source.read(codex, path, stale(path)))!;

      expect(report.status, AgentActivityStatus.idle);
      expect(report.detail, 'payload.type=task_complete');
    });

    test('a run of them still resolves', () async {
      final path = write([
        customToolCallOutput,
        turnContext,
        tokenCount,
        tokenCount,
      ]);

      expect(
        (await source.read(codex, path, fresh(path)))!.status,
        AgentActivityStatus.working,
      );
    });

    test('the walk stops at a stale working record', () async {
      // The property that makes stepping back safe. A turn that started and
      // then stopped being written to must age into `unknown` — not step back
      // over the dead turn to the *previous* turn's `task_complete` and report
      // the session finished.
      final path = write([taskComplete, taskStarted, tokenCount]);

      final report = (await source.read(codex, path, stale(path)))!;

      expect(report.status, AgentActivityStatus.unknown);
      expect(report.detail, 'stale: payload.type=task_started');
    });

    test('the walk is bounded, and gives up rather than digging', () async {
      // Eight records, from measurement: 48 of the owner's 52 rollouts need no
      // walk at all and the rest need three or four. A file buried under more
      // noise than that reads `unknown`, which is a first-class answer.
      final path = write([
        taskComplete,
        ...List.filled(12, stateHeader),
      ]);

      expect(
        (await source.read(codex, path, stale(path)))!.status,
        AgentActivityStatus.unknown,
      );
    });

    test('Claude Code does not walk back', () async {
      // Opt-in per agent, and Claude Code deliberately opts out: walking back
      // would reclassify 52 of the owner's 559 transcripts from `unknown` to
      // `idle`, and `idle` is what fires a completion notification.
      final path = write([
        '{"type":"assistant","message":{"content":"done"}}',
        '{"type":"last-prompt","prompt":"next"}',
      ]);

      expect(
        (await source.read(claude, path, stale(path)))!.status,
        AgentActivityStatus.unknown,
      );
    });
  });

  group('the population', () {
    /// The owner's store, by the shape of each rollout's **last** record:
    /// 27 `task_complete`, 13 `response_item`/`message`/assistant, 4 legacy
    /// `message`, 4 `turn_aborted`, 2 header records and 2 `token_count`.
    List<String> census() => [
      for (var i = 0; i < 27; i++)
        write([taskStarted, functionCall, taskComplete]),
      for (var i = 0; i < 13; i++) write([userMessage, assistantMessage]),
      for (var i = 0; i < 4; i++) write([stateHeader, legacyAssistantMessage]),
      for (var i = 0; i < 4; i++) write([taskStarted, turnAborted]),
      // One header record over a classifiable turn, and one over the 2025
      // file whose last classifiable record is 33 records back.
      write([legacyAssistantMessage, stateHeader]),
      write([legacyAssistantMessage, ...List.filled(33, stateHeader)]),
      // Both `token_count`-terminated files in the store sit on a turn that
      // was still running when the CLI stopped.
      write([userMessage, turnContext, tokenCount]),
      write([customToolCallOutput, turnContext, tokenCount]),
    ];

    test('39 unknown / 13 idle / 0 working becomes 49 idle / 2 working', () async {
      final paths = census();
      expect(paths, hasLength(52));

      final counts = <AgentActivityStatus, int>{};
      for (final path in paths) {
        // Fresh, so a `working` record reads as working rather than aging out:
        // the point of the figure is what the rules can classify, and the
        // staleness rule is tested on its own above.
        final report = (await source.read(codex, path, fresh(path)))!;
        counts.update(report.status, (n) => n + 1, ifAbsent: () => 1);
      }

      expect(counts[AgentActivityStatus.idle], 49);
      expect(counts[AgentActivityStatus.working], 2);
      expect(counts[AgentActivityStatus.unknown], 1);
      expect(counts[AgentActivityStatus.failed], isNull);
      expect(counts[AgentActivityStatus.awaitingApproval], isNull);
    });
  });
}
