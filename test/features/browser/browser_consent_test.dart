import 'package:karmashala/src/features/browser/application/browser_consent_providers.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:flutter_test/flutter_test.dart';

/// The consent record: what it remembers, what it forgets, and what it does
/// when it cannot tell.
///
/// Every "cannot tell" case here asserts a *denial*. That is the property worth
/// defending — a permission store whose error path is permissive is worse than
/// no store, because it reads to a reviewer as if a decision was made.
void main() {
  BrowserConsentStore store() => BrowserConsentStore(MemoryConsentJournal());

  group('grants', () {
    test('nothing is granted until somebody grants it', () {
      expect(store().isGranted('p1', BrowserCapability.evaluate), isFalse);
    });

    test('a grant is remembered, with when and by whom', () {
      final consent = store();
      final at = DateTime.utc(2026, 3, 4, 5, 6);
      consent.grant(
        'p1',
        BrowserCapability.evaluate,
        grantedBy: 'Settings → Tools → Browser',
        at: at,
      );
      final grant = consent.grantFor('p1', BrowserCapability.evaluate)!;
      expect(grant.grantedAt, at);
      expect(grant.grantedBy, 'Settings → Tools → Browser');
    });

    test('a grant covers its own project and no other', () {
      final consent = store()
        ..grant('p1', BrowserCapability.evaluate, grantedBy: 'settings');
      expect(consent.isGranted('p1', BrowserCapability.evaluate), isTrue);
      expect(consent.isGranted('p2', BrowserCapability.evaluate), isFalse);
    });

    test('revoking takes it back', () {
      final consent = store()
        ..grant('p1', BrowserCapability.evaluate, grantedBy: 'settings')
        ..revoke('p1', BrowserCapability.evaluate);
      expect(consent.isGranted('p1', BrowserCapability.evaluate), isFalse);
      expect(consent.all(), isEmpty);
    });

    test('granting twice refreshes rather than duplicating', () {
      final consent = store()
        ..grant(
          'p1',
          BrowserCapability.evaluate,
          grantedBy: 'settings',
          at: DateTime.utc(2026),
        )
        ..grant(
          'p1',
          BrowserCapability.evaluate,
          grantedBy: 'settings',
          at: DateTime.utc(2027),
        );
      expect(consent.all(), hasLength(1));
      expect(consent.all().single.grantedAt, DateTime.utc(2027));
    });

    test('grants survive being written and read back', () {
      final journal = MemoryConsentJournal();
      BrowserConsentStore(
        journal,
      ).grant('p1', BrowserCapability.evaluate, grantedBy: 'settings');
      expect(
        BrowserConsentStore(journal).isGranted('p1',
            BrowserCapability.evaluate),
        isTrue,
      );
    });
  });

  group('storage that cannot be read grants nothing', () {
    test('corrupt JSON is not a grant', () {
      final journal = MemoryConsentJournal()
        ..write(BrowserConsentStore.storageKey, '{not json');
      expect(BrowserConsentStore(journal).all(), isEmpty);
    });

    test('a row naming a capability this build does not know is dropped', () {
      final journal = MemoryConsentJournal()
        ..write(
          BrowserConsentStore.storageKey,
          '{"grants":[{"scope":"p1","capability":"read_all_the_cookies",'
              '"grantedAt":"2026-01-01T00:00:00Z","grantedBy":"x"}]}',
        );
      expect(BrowserConsentStore(journal).all(), isEmpty);
    });

    test('a row with no readable date is dropped', () {
      final journal = MemoryConsentJournal()
        ..write(
          BrowserConsentStore.storageKey,
          '{"grants":[{"scope":"p1","capability":"evaluate",'
              '"grantedAt":"whenever","grantedBy":"x"}]}',
        );
      expect(BrowserConsentStore(journal).all(), isEmpty);
    });
  });

  group('the gate', () {
    test('an unresolvable project refuses and says how to fix it', () {
      final decision = const DeniedBrowserConsent().check(
        BrowserCapability.evaluate,
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('Settings'));
    });

    test('a resolved project with no grant names the project', () {
      final gate = ProjectScopedBrowserConsent(
        store: store(),
        scope: (id: 'p1', name: 'Karmashala'),
      );
      final decision = gate.check(BrowserCapability.evaluate);
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('Karmashala'));
      // The refusal has to be actionable by the agent's *user*, so it names
      // both the place to say yes and the tools that work meanwhile.
      expect(decision.reason, contains('Settings → Tools → Browser'));
      expect(decision.reason, contains('browser_find'));
    });

    test('a granted project is allowed', () {
      final consent = store()
        ..grant('p1', BrowserCapability.evaluate, grantedBy: 'settings');
      final gate = ProjectScopedBrowserConsent(
        store: consent,
        scope: (id: 'p1', name: 'Karmashala'),
      );
      expect(gate.check(BrowserCapability.evaluate).allowed, isTrue);
    });

    test('a revocation takes effect on the next check, not the next run', () {
      final consent = store()
        ..grant('p1', BrowserCapability.evaluate, grantedBy: 'settings');
      final gate = ProjectScopedBrowserConsent(
        store: consent,
        scope: (id: 'p1', name: 'Karmashala'),
      );
      expect(gate.check(BrowserCapability.evaluate).allowed, isTrue);
      consent.revoke('p1', BrowserCapability.evaluate);
      expect(gate.check(BrowserCapability.evaluate).allowed, isFalse);
    });
  });

  test('capability tokens are stable across a rename of the enum', () {
    expect(BrowserCapability.evaluate.token, 'evaluate');
    expect(BrowserCapability.byToken('evaluate'), BrowserCapability.evaluate);
    expect(BrowserCapability.byToken('nope'), isNull);
  });
}
