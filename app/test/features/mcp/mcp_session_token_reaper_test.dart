import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:karmashala/src/features/mcp/mcp_session_token_reaper.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// A capability token speaks for one session for as long as it is valid, so it
/// has to stop being valid when that session stops existing.
///
/// The distinction every test here turns on: a session whose **tab** was closed
/// is still running and can be resumed, and taking its token would break the
/// agent still holding the URL. A session that finished, was archived, or was
/// deleted is over, and a config file left on disk must not keep speaking for
/// it.
void main() {
  late AppDatabase db;
  late FakeSessionRows sessions;
  late ProviderContainer container;
  late McpCallerRegistry callers;
  late McpSessionTokenReaper reaper;

  setUp(() async {
    db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final fake = FakeDataServer()..mirrorInto(db);
    fake.projectRows.insert(project());
    fake.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    sessions = fake.sessionRows;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await fake.override(),
      ],
    );
    addTearDown(container.dispose);
    callers = McpCallerRegistry();
    reaper = McpSessionTokenReaper(container, callers)..start();
    addTearDown(reaper.stop);
  });

  /// Inserts a running session and mints its token, returning the token.
  String liveSession(String id) {
    sessions.insert(session(id: id, status: SessionStatus.running));
    return callers.tokenFor(id);
  }

  void sessionListChanged() =>
      container.read(sessionsRevisionProvider.notifier).bump();

  for (final over in [
    SessionStatus.completed,
    SessionStatus.failed,
    SessionStatus.cancelled,
  ]) {
    test('a ${over.name} session stops being speakable-for', () {
      final token = liveSession('s-${over.name}');
      expect(callers.sessionFor(token), 's-${over.name}');

      sessions.updateStatus('s-${over.name}', over);
      sessionListChanged();

      expect(callers.sessionFor(token), isNull);
    });
  }

  test('an archived session stops being speakable-for', () {
    final token = liveSession('s-archived');

    sessions.markArchived('s-archived', testTime);
    sessionListChanged();

    expect(callers.sessionFor(token), isNull);
  });

  test('a deleted session takes its token with it', () {
    final token = liveSession('s-gone');

    sessions.delete('s-gone');
    sessionListChanged();

    expect(callers.sessionFor(token), isNull);
  });

  test('a session whose tab was closed keeps its token', () {
    final token = liveSession('s-detached');

    // What `SessionAdoptionService._releasePane` does, and all it does: the
    // conversation still exists and can be resumed, so the agent holding this
    // URL is still that session.
    sessions.updatePaneId('s-detached', null);
    sessionListChanged();

    expect(callers.sessionFor(token), 's-detached');
  });

  test('a token is retired once, and a re-launch mints a fresh one', () {
    final first = liveSession('s-reused');
    sessions.updateStatus('s-reused', SessionStatus.completed);
    sessionListChanged();
    expect(callers.sessionFor(first), isNull);

    sessions.updateStatus('s-reused', SessionStatus.running);
    final second = callers.tokenFor('s-reused');
    expect(second, isNot(first));
    sessionListChanged();
    expect(callers.sessionFor(second), 's-reused');
  });

  test('a stopped reaper stops sweeping', () {
    final token = liveSession('s-after-stop');
    reaper.stop();

    sessions.updateStatus('s-after-stop', SessionStatus.completed);
    sessionListChanged();

    expect(callers.sessionFor(token), 's-after-stop');
  });

  test('the control server runs one for its own registry', () async {
    final tmp = Directory.systemTemp.createTempSync('karmashala_token_reaper_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
    addTearDown(server.stop);

    sessions.insert(session(id: 's-served', status: SessionStatus.running));
    final url = server.mcpUrlFor(
      's-served',
      environment: EnvironmentKind.windowsNative,
    );
    final token = Uri.parse(url!).pathSegments.last;
    expect(server.callers.sessionFor(token), 's-served');

    sessions.updateStatus('s-served', SessionStatus.completed);
    sessionListChanged();

    expect(
      server.callers.sessionFor(token),
      isNull,
      reason: 'the config file left on disk must not keep speaking for it',
    );
    // Nothing about the handshake changed: the server is still serving.
    expect(File(p.join(tmp.path, 'mcp_bridge.json')).existsSync(), isTrue);
    expect(
      jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync()),
      isA<Map<String, Object?>>(),
    );
  });
}
