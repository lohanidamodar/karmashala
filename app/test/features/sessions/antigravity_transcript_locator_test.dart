import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fixtures.dart';

/// **Finding an Antigravity conversation the store scan does not list.**
///
/// Antigravity places most conversations in no directory at all, so the scan
/// that keys every transcript by `<agent>/<session>` simply has no row for
/// them — 43 of the 44 with a transcript on this machine carry a
/// `conversations/<id>.db` record, and the scan lists a handful. Without a
/// second route the chat view refuses a session whose transcript is right
/// there, which reads to a user as "Antigravity has no chat view" when the
/// truth is "we did not look in the one place it keeps them".
void main() {
  late Directory store;

  setUp(() {
    store = Directory.systemTemp.createTempSync('karmashala_agy_locator_');
  });
  tearDown(() {
    if (store.existsSync()) store.deleteSync(recursive: true);
  });

  String writeRecord(String id, {String extension = '.db'}) {
    final dir = Directory(p.join(store.path, 'conversations'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, '$id$extension'))
      ..writeAsStringSync('protobuf');
    return file.path;
  }

  SessionTranscriptLocator locatorWith({
    List<DetectedSession> scanned = const [],
  }) {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cliStoreLocatorProvider.overrideWithValue(
          FixedLocator([
            CliStore(
              environmentId: 'windows',
              homesByAgentId: {AgentIds.antigravity: store.path},
            ),
          ]),
        ),
        cliDetectionServiceProvider.overrideWithValue(_Detection(scanned)),
      ],
    );
    addTearDown(container.dispose);
    return container.read(sessionTranscriptLocatorProvider);
  }

  test('a conversation the scan never listed is found by its id', () async {
    final record = writeRecord('conv-1');

    final found = await locatorWith().locate(
      agentId: AgentIds.antigravity,
      externalSessionId: 'conv-1',
    );

    expect(found, record);
  });

  test('the older .pb record is found too', () async {
    final record = writeRecord('conv-2', extension: '.pb');

    final found = await locatorWith().locate(
      agentId: AgentIds.antigravity,
      externalSessionId: 'conv-2',
    );

    expect(found, record);
  });

  test('a conversation with no record at all is not invented', () async {
    final found = await locatorWith().locate(
      agentId: AgentIds.antigravity,
      externalSessionId: 'conv-missing',
    );

    expect(found, isNull);
  });

  test('another agent never takes this route', () async {
    writeRecord('conv-1');

    final found = await locatorWith().locate(
      agentId: AgentIds.claudeCode,
      externalSessionId: 'conv-1',
    );

    expect(found, isNull);
  });

  test('what the scan did list still wins, and costs no second look', () async {
    final record = writeRecord('conv-1');
    final scanned = DetectedSession(
      cli: AgentIds.antigravity,
      sessionId: 'conv-1',
      cwd: repository().path,
      filePath: p.join(store.path, 'somewhere-else.db'),
      storeHome: store.path,
    );

    final found = await locatorWith(
      scanned: [scanned],
    ).locate(agentId: AgentIds.antigravity, externalSessionId: 'conv-1');

    expect(found, isNot(record));
    expect(found, scanned.filePath);
  });
}

class _Detection implements CliDetectionService {
  _Detection(this.sessions);

  final List<DetectedSession> sessions;

  @override
  Future<List<DetectedProject>> detect(
    List<CliStore> stores,
    Map<String, Object?> environmentsById,
  ) async => [
    if (sessions.isNotEmpty)
      DetectedProject(
        canonicalKey: 'demo',
        displayPath: r'C:\src\demo\app',
        sessions: List.of(sessions),
        subagentSessions: const [],
      ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the locator tests reach nothing else');
}
