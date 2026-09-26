import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/browser/application/browser_consent_providers.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';

/// Which project a browser call belongs to — the question the consent gate
/// cannot skip.
///
/// A grant is only meaningful if the thing being checked against it is the
/// project the developer had in mind. These tests pin the two answers that are
/// available (the caller's own session, then the checkout the app is pointed
/// at) and, more importantly, pin what happens when neither is: a refusal, not
/// a pass.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    server = FakeDataServer(clock: () => testTime).mirrorInto(db)
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1'));
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  test('a calling session resolves to its checkout\'s project', () {
    final scope = resolveBrowserConsentScope(container, callerSessionId: 's1');
    expect(scope?.id, 'p1');
    expect(scope?.name, 'Demo', reason: 'the refusal has to name it readably');
  });

  test('a caller with no session falls back to the selected checkout', () {
    // An external MCP client on the launcher config has no session of its own,
    // and the checkout the Explorer is pointed at is the only project context
    // that exists for it.
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    expect(resolveBrowserConsentScope(container)?.id, 'p1');
  });

  test('a session id nobody recognises still falls back, not through', () {
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    expect(
      resolveBrowserConsentScope(container, callerSessionId: 'ghost')?.id,
      'p1',
    );
  });

  test('no session and no selection resolves to nothing', () {
    expect(resolveBrowserConsentScope(container), isNull);
  });

  test('an unresolvable scope refuses rather than allowing', () {
    // The one property worth defending: "we could not tell which project this
    // is" must never read as "granted".
    final gate = browserConsentFor(container);
    expect(gate, isA<DeniedBrowserConsent>());
    expect(gate.check(BrowserCapability.evaluate).allowed, isFalse);
  });

  test('a resolved scope with no grant is still refused', () {
    final gate = browserConsentFor(container, callerSessionId: 's1');
    final decision = gate.check(BrowserCapability.evaluate);
    expect(decision.allowed, isFalse);
    expect(decision.reason, contains('Demo'));
  });

  test('a grant recorded against the project lets the call through', () {
    container
        .read(browserConsentStoreProvider)
        .grant('p1', BrowserCapability.evaluate, grantedBy: 'settings');
    expect(
      browserConsentFor(
        container,
        callerSessionId: 's1',
      ).check(BrowserCapability.evaluate).allowed,
      isTrue,
    );
  });

  test('a grant for another project does not carry over', () {
    container
        .read(browserConsentStoreProvider)
        .grant('p2', BrowserCapability.evaluate, grantedBy: 'settings');
    expect(
      browserConsentFor(
        container,
        callerSessionId: 's1',
      ).check(BrowserCapability.evaluate).allowed,
      isFalse,
    );
  });

  test('the grant outlives the container it was made in', () async {
    // It is kept at the server, so restarting the app does not quietly
    // re-ask — and, just as importantly, does not quietly forget a revocation.
    container
        .read(browserConsentStoreProvider)
        .grant('p1', BrowserCapability.evaluate, grantedBy: 'settings');
    await pumpEventQueue();
    final second = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
      ],
    );
    addTearDown(second.dispose);
    expect(
      second
          .read(browserConsentStoreProvider)
          .isGranted('p1', BrowserCapability.evaluate),
      isTrue,
    );
  });
}
