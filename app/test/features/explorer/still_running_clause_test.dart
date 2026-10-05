import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/sessions/application/background_runs_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';

import '../../support/fixtures.dart';

/// A session row's "still running" reads the runs the composer's strip
/// lists, so it clears when the last of them ends — not the hook's list of
/// background work, which a Stop that never came leaves standing.
void main() {
  SessionBackgroundRun run(String description, BackgroundRunState state) =>
      SessionBackgroundRun(
        run: BackgroundRun(
          id: description,
          kind: BackgroundRunKind.command,
          state: state,
          description: description,
        ),
        startedAt: testTime,
      );

  String? clauseFor(List<SessionBackgroundRun> runs) {
    final container = ProviderContainer(
      overrides: [
        sessionBackgroundRunsProvider.overrideWith((ref, _) => runs),
        // The hook still lists the run as in flight.
        sessionStatusLookupProvider.overrideWithValue(
          (id) => AgentStatusReport(
            agentId: AgentIds.claudeCode,
            sessionId: id,
            status: AgentActivityStatus.working,
            observedAt: testTime,
            source: AgentStatusSource.hook,
            inFlight: const ['Analyze everything and run the tests'],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container.read(sessionStillRunningProvider('s1'));
  }

  test('names the run the strip shows running', () {
    expect(
      clauseFor([
        run('Analyze everything and run the tests', BackgroundRunState.running),
        run('watch the build', BackgroundRunState.completed),
      ]),
      'still running: Analyze everything and run the tests',
    );
  });

  test('says nothing once the last run has ended, whatever the hook last '
      'listed', () {
    expect(
      clauseFor([
        run(
          'Analyze everything and run the tests',
          BackgroundRunState.completed,
        ),
      ]),
      isNull,
    );
    expect(clauseFor(const []), isNull);
  });
}
