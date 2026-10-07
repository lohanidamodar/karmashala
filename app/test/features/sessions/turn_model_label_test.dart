import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_model_catalog_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_active_model_providers.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// A chat turn's model line reads the catalogue's label — "Opus 5.5", not
/// `claude-opus-5-5` — once the catalogue has it, the raw id only where it
/// has no entry.
void main() {
  testWidgets('a terminal Claude session labels its turns from its catalogue', (
    tester,
  ) async {
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: 'ext-1',
      ),
    );
    final listed = Completer<List<AgentModel>?>();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        discoveredModelsInProvider.overrideWith((ref, key) => listed.future),
      ],
    );
    addTearDown(container.dispose);
    final labels = <String>[];
    final watched = container.listen(
      sessionModelLabelerProvider('s1'),
      (_, labelOf) => labels.add(labelOf('claude-opus-5-5')),
      fireImmediately: true,
    );
    addTearDown(watched.close);

    expect(labels.last, 'claude-opus-5-5', reason: 'no catalogue yet');

    listed.complete(const [
      AgentModel(
        id: 'opus',
        label: 'Opus 5.5',
        summary: 'For complex work and everyday tasks',
        resolvedId: 'claude-opus-5-5',
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 10));

    expect(labels.last, 'Opus 5.5', reason: 'the turn is relabelled');
    final labelOf = container.read(sessionModelLabelerProvider('s1'));
    expect(labelOf('opus'), 'Opus 5.5');
    expect(
      labelOf('claude-mystery-9'),
      'claude-mystery-9',
      reason: 'an id the catalogue does not name stays as it was written',
    );
  });
}
