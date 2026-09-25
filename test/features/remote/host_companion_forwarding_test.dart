import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_host_lifecycle.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The session host serves the phone companion and forwards what only this app
/// can answer over the lifecycle link; this app answers with the same bindings
/// its own server would, from the same providers the desktop draws.
void main() {
  late AppDatabase db;
  late FakeHostLifecycle host;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', title: 'Work'));
    host = FakeHostLifecycle();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostLifecycleSourceProvider.overrideWithValue(host),
        remoteDeliveryStageProvider.overrideWithValue((id) async => null),
        remoteApprovalEvidenceProvider.overrideWithValue((id) async => null),
        remoteSessionPresenceProvider.overrideWithValue(
          (id) => (note: null, lastSeen: null),
        ),
        remoteFolderMissingProvider.overrideWithValue((path) => false),
        remoteCheckoutBranchProvider.overrideWithValue((path) => null),
      ],
    );
    addTearDown(() {
      container.dispose();
      db.close();
    });
    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    await _settle();
  });

  test(
    'a forwarded session lookup is answered from this app\'s own view',
    () async {
      host.companionCallLink.add(
        CompanionCallMessage(
          callId: 1,
          method: CompanionMethod.sessionById.wire,
          arguments: const {'sessionId': 's1'},
        ),
      );
      await _settle();

      final answer = host.companionAnswers.single;
      expect(answer.code, isNull);
      final snapshot = RemoteSessionSnapshot.fromJson(
        (answer.result!['session']! as Map).cast<String, Object?>(),
      );
      expect(snapshot.sessionId, 's1');
      expect(snapshot.title, 'Work');
    },
  );

  test(
    'a request the app cannot read is refused in the phone\'s own words',
    () async {
      host.companionCallLink.add(
        CompanionCallMessage(
          callId: 2,
          method: CompanionMethod.answerQuestion.wire,
          arguments: const {'sessionId': 's1'},
        ),
      );
      await _settle();

      final answer = host.companionAnswers.single;
      expect(answer.code, ErrorCode.badRequest.wire);
    },
  );
}
