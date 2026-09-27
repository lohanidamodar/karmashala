import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/browser/server_browser_consent.dart';
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

/// Which project a browser tool call belongs to, at the server — the
/// question the consent gate cannot skip. The calling session's checkout's
/// project is the only answer; "could not tell" must never read as granted.
void main() {
  late ToolHarness h;
  late ServerBrowserConsent consent;

  setUp(() {
    h = ToolHarness();
    consent = ServerBrowserConsent(h.db);
  });
  tearDown(() => h.dispose());

  /// A grant made the way a client makes one: its Settings writes the
  /// `browser.consent.v1` preference through the data API.
  void grantFromAClient(String projectId) {
    final journal = MemoryConsentJournal();
    final raw = h.db.readMetadata(BrowserConsentStore.storageKey);
    if (raw != null) journal.write(BrowserConsentStore.storageKey, raw);
    BrowserConsentStore(
      journal,
    ).grant(projectId, BrowserCapability.evaluate, grantedBy: 'settings');
    h.client.handle(
      PreferenceSet(
        BrowserConsentStore.storageKey,
        journal.read(BrowserConsentStore.storageKey)!,
      ),
    );
  }

  test('a calling session resolves to its checkout\'s project', () {
    final scope = consent.scopeOf('s1');
    expect(scope?.id, 'p1');
    expect(scope?.name, 'Demo', reason: 'the refusal has to name it readably');
  });

  test('no session, or one nobody recognises, resolves to nothing', () {
    expect(consent.scopeOf(null), isNull);
    expect(consent.scopeOf(''), isNull);
    expect(consent.scopeOf('ghost'), isNull);
  });

  test('an unresolvable scope refuses rather than allowing', () {
    final gate = consent.consentFor(null);
    expect(gate, isA<DeniedBrowserConsent>());
    expect(gate.check(BrowserCapability.evaluate).allowed, isFalse);
  });

  test('a resolved scope with no grant is still refused, naming it', () {
    final decision = consent.consentFor('s1').check(BrowserCapability.evaluate);
    expect(decision.allowed, isFalse);
    expect(decision.reason, contains('Demo'));
  });

  test('a grant a client recorded lets the call through, read per call', () {
    final gate = consent.consentFor('s1');
    expect(gate.check(BrowserCapability.evaluate).allowed, isFalse);
    grantFromAClient('p1');
    expect(gate.check(BrowserCapability.evaluate).allowed, isTrue);
  });

  test('a grant for another project does not carry over', () {
    grantFromAClient('p2');
    expect(
      consent.consentFor('s1').check(BrowserCapability.evaluate).allowed,
      isFalse,
    );
  });
}
