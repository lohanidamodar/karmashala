import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart' show CommandRunnerFactory;
import 'package:agent_cli/read.dart' show subagentsDirectoryFor;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/session_record_readings.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A subagent's tokens, counted by its parent agent's own reader over the
/// delegate's record — and only a record of that session's, under a bound.
void main() {
  late Directory root;
  late AppDatabase db;
  late String parent;
  late String delegate;

  setUp(() {
    root = Directory.systemTemp.createTempSync('subagent_tokens');
    db = AppDatabase.memory();
    parent = p.join(root.path, 's1.jsonl');
    File(parent).writeAsStringSync(
      '{"type":"user","message":{"role":"user","content":"go"}}\n',
    );
    final directory = Directory(subagentsDirectoryFor(parent))
      ..createSync(recursive: true);
    delegate = p.join(directory.path, 'agent-1.jsonl');
    File(delegate).writeAsStringSync(
      '{"type":"assistant","timestamp":"2026-10-03T09:00:00Z",'
      '"message":{"id":"m1","role":"assistant","model":"claude-haiku",'
      '"content":[{"type":"text","text":"done"}],'
      '"usage":{"input_tokens":100,"output_tokens":20}}}\n',
    );
  });

  tearDown(() {
    db.close();
    root.deleteSync(recursive: true);
  });

  SessionRecordReadings readings() => SessionRecordReadings(
    lookUp: (_) async =>
        (path: parent, agentId: AgentIds.claudeCode, absence: null),
    registry: AgentRegistry.builtIn,
    sessions: SessionDao(db),
    rows: CheckoutRows(db),
    runners: const CommandRunnerFactory(),
  );

  test('counts the delegate\'s own usage records', () async {
    final tokens = await readings().subagentTokensOf('s1', delegate);
    expect(tokens.total, 120);
    expect(tokens.gap, isNull);
  });

  test('a record over the bound is not read, and says so', () async {
    final tokens = await readings().subagentTokensOf(
      's1',
      delegate,
      maxBytes: 10,
    );
    expect(tokens.total, isNull);
    expect(tokens.gap, SubagentTokensGap.tooLarge);
  });

  test('a path outside the session\'s subagents is never read', () async {
    final tokens = await readings().subagentTokensOf('s1', parent);
    expect(tokens.total, isNull);
    expect(tokens.gap, SubagentTokensGap.notRecorded);
  });
}
