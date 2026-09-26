import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

class _Live extends LiveAgentStatuses {
  @override
  Map<String, AgentActivityStatus> build() => const {
    's1': AgentActivityStatus.working,
  };
}

/// A hung turn raises no event, so the page has to notice by itself — once, at
/// the instant the evidence ages past [kQuietAfter], and not on a tick.
void main() {
  late MovableClock clock;
  late DateTime evidenceAt;

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(clock),
        liveAgentStatusesProvider.overrideWith(_Live.new),
        sessionStatusLookupProvider.overrideWithValue(
          (id) => AgentStatusReport(
            agentId: AgentIds.claudeCode,
            sessionId: id,
            status: AgentActivityStatus.working,
            observedAt: evidenceAt,
            source: AgentStatusSource.hook,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    clock = MovableClock(testTime);
    evidenceAt = testTime;
  });

  testWidgets('a working session turns quiet when its evidence ages', (
    tester,
  ) async {
    final c = container();
    final sub = c.listen(quietSessionsProvider, (_, _) {});
    expect(sub.read(), isEmpty);

    clock.advance(kQuietAfter);
    await tester.pump(kQuietAfter);
    expect(sub.read(), {'s1'});

    // Disposing runs onDispose now; an autoDispose that is merely scheduled
    // would leave the armed timer for the pending-timer check.
    c.dispose();
  });

  testWidgets('new evidence moves it back within a minute', (tester) async {
    clock.advance(kQuietAfter);
    final c = container();
    final sub = c.listen(quietSessionsProvider, (_, _) {});
    expect(sub.read(), {'s1'});

    // Still `working`, so no status move announces it; the re-read does.
    evidenceAt = clock.now;
    clock.advance(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(sub.read(), isEmpty);

    // Disposing runs onDispose now; an autoDispose that is merely scheduled
    // would leave the armed timer for the pending-timer check.
    c.dispose();
  });
}
