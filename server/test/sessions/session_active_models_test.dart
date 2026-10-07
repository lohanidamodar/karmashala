import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart' show CommandRunnerFactory;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/session_active_models.dart';
import 'package:karmashala_host/src/sessions/session_record_readings.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// What a session's agent last said it runs, kept by the server: told when
/// it moves, read from a terminal session's record, greeted to a late client.
void main() {
  final t0 = DateTime.utc(2026, 10, 7, 9);
  late List<SessionActiveModelChanged> told;

  setUp(() => told = []);

  SessionActiveModels keeper({
    Future<ActiveModelReading?> Function(String sessionId)? readRecord,
  }) => SessionActiveModels(
    announce: told.add,
    readRecord: readRecord,
    now: () => t0,
  );

  test('a report is told once per model, with when it was first seen', () {
    final models = keeper();
    expect(models.of('s1'), isNull);
    expect(models.modelWords('s1'), 'not recorded');

    models.report('s1', 'gpt-6-astra', source: ActiveModelSource.agent);
    models.report('s1', 'gpt-6-astra', source: ActiveModelSource.agent);
    models.report('s1', 'gpt-6-astra-mini', source: ActiveModelSource.agent);

    expect(told.map((c) => c.modelId), ['gpt-6-astra', 'gpt-6-astra-mini']);
    expect(told.first.observedAt, t0);
    expect(told.first.source, ActiveModelSource.agent);
    expect(models.modelWords('s1'), 'gpt-6-astra-mini');
    expect(models.greeting(), [told.last]);
  });

  test('a burst of refreshes reads the record twice, not once per edge, and '
      'keeps the time the record gave', () async {
    var reads = 0;
    final gate = Completer<void>();
    final models = keeper(
      readRecord: (id) async {
        reads++;
        await gate.future;
        return ActiveModelReading(
          'claude-opus-5-5',
          at: DateTime.utc(2026, 10, 7, 8),
        );
      },
    );
    final first = models.refresh('s1');
    unawaited(models.refresh('s1'));
    unawaited(models.refresh('s1'));
    gate.complete();
    await first;
    await pumpEventQueue();
    expect(reads, 2);
    expect(told.single.modelId, 'claude-opus-5-5');
    expect(told.single.observedAt, DateTime.utc(2026, 10, 7, 8));
    expect(told.single.source, ActiveModelSource.record);
  });

  test('a record that names nothing, or cannot be read, leaves nothing '
      'recorded', () async {
    final models = keeper(readRecord: (id) async => throw StateError('gone'));
    expect(await models.current('s1'), isNull);
    expect(told, isEmpty);
  });

  group('read from a terminal session\'s record', () {
    late AppDatabase db;
    late Directory temp;

    setUp(() {
      db = AppDatabase.memory();
      temp = Directory.systemTemp.createTempSync('active_models_test');
    });

    tearDown(() {
      db.close();
      temp.deleteSync(recursive: true);
    });

    SessionRecordReadings readings(String path, String agentId) =>
        SessionRecordReadings(
          lookUp: (_) async => (path: path, agentId: agentId, absence: null),
          registry: AgentRegistry.builtIn,
          sessions: SessionDao(db),
          rows: CheckoutRows(db),
          runners: const CommandRunnerFactory(),
        );

    test('Claude Code: the newest reply past a long tail', () async {
      final path = '${temp.path}/s1.jsonl';
      final filler = List.filled(
        3000,
        '{"type":"user","message":{"role":"user","content":"${'x' * 100}"}}',
      ).join('\n');
      File(path).writeAsStringSync(
        '{"type":"assistant","timestamp":"2026-10-07T09:00:00Z",'
        '"message":{"model":"claude-opus-5-5","content":[]}}\n'
        '$filler\n',
      );
      final models = keeper(
        readRecord: readings(path, AgentIds.claudeCode).activeModel,
      );
      final current = await models.current('s1');
      expect(current?.modelId, 'claude-opus-5-5');
      expect(current?.observedAt, DateTime.utc(2026, 10, 7, 9));
    });

    test('Codex: its latest turn_context', () async {
      final path = '${temp.path}/rollout.jsonl';
      File(path).writeAsStringSync(
        '{"timestamp":"2026-10-07T05:05:30Z","type":"session_meta",'
        '"payload":{"model":"gpt-6-astra"}}\n'
        '{"timestamp":"2026-10-07T05:06:00Z","type":"turn_context",'
        '"payload":{"model":"gpt-6-astra-mini"}}\n',
      );
      expect(
        (await readings(path, AgentIds.codex).activeModel('s1'))?.modelId,
        'gpt-6-astra-mini',
      );
    });

    test('a record gone from disk reads as none', () async {
      expect(
        await readings(
          '${temp.path}/missing.jsonl',
          AgentIds.claudeCode,
        ).activeModel('s1'),
        isNull,
      );
    });
  });
}
