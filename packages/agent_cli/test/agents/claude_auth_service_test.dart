import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/data/claude_auth_service.dart';
import 'package:agent_cli/src/agents/domain/claude_account.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';
import '../support/temp_directory.dart';

void main() {
  group('on macOS', _macOsCredentialsTests);

  group('parseClaudeSnapshot', () {
    test('reads identity and token metadata when signed in', () {
      final snap = parseClaudeSnapshot(
        environmentId: 'wsl:archlinux',
        credentials: {
          'claudeAiOauth': {
            'accessToken': 'a',
            'expiresAt': 1785221891296,
            'subscriptionType': 'max',
            'rateLimitTier': 'default_claude_max_20x',
          },
        },
        config: {
          'oauthAccount': {
            'emailAddress': 'me@x.com',
            'organizationName': 'My Org',
            'organizationUuid': 'org-1',
          },
        },
      );
      expect(snap.isSignedIn, isTrue);
      expect(snap.email, 'me@x.com');
      expect(snap.organizationName, 'My Org');
      expect(snap.subscriptionType, 'max');
      expect(snap.rateLimitTier, 'default_claude_max_20x');
      expect(
        snap.accessTokenExpiresAt,
        DateTime.fromMillisecondsSinceEpoch(1785221891296),
      );
    });

    test('is signed out when there is no oauthAccount email', () {
      final snap = parseClaudeSnapshot(
        environmentId: 'windows',
        credentials: {
          'claudeAiOauth': {'accessToken': 'a'},
        },
        config: {},
      );
      expect(snap.isSignedIn, isFalse);
      expect(snap.email, isNull);
    });
  });

  group('ClaudeAuthService capture/switch', () {
    late Directory dir;
    late ClaudeAuthPaths paths;
    late ClaudeAuthService service;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('claude_auth_test');
      paths = ClaudeAuthPaths(
        environmentId: 'test',
        credentialsFile: '${dir.path}/.credentials.json',
        configFile: '${dir.path}/.claude.json',
      );
      service = ClaudeAuthService(
        ids: SequentialIdGenerator(),
        clock: FixedClock(DateTime.utc(2026, 1, 1)),
      );
    });

    tearDown(() => removeTempDirectory(dir));

    void writeCreds(Map<String, dynamic> m) =>
        File(paths.credentialsFile).writeAsStringSync(jsonEncode(m));
    void writeConfig(String raw) =>
        File(paths.configFile).writeAsStringSync(raw);

    test('capture reads the current account', () async {
      writeCreds({
        'claudeAiOauth': {'accessToken': 'tok', 'subscriptionType': 'max'},
        'mcpOAuth': {'server': 'keep-me'},
      });
      writeConfig(
        jsonEncode({
          'oauthAccount': {
            'emailAddress': 'a@x.com',
            'organizationUuid': 'org-a',
            'organizationName': 'Org A',
          },
        }),
      );

      final account = await service.capture(paths);
      expect(account.email, 'a@x.com');
      expect(account.organizationUuid, 'org-a');
      expect(account.subscriptionType, 'max');
      expect(account.claudeAiOauth['accessToken'], 'tok');
      expect(account.oauthAccount!['organizationName'], 'Org A');
    });

    test(
      'a credentials file that is not JSON is named, not read as signed out',
      () async {
        File(paths.credentialsFile).writeAsStringSync('{"claudeAiOauth": ');
        writeConfig(
          jsonEncode({
            'oauthAccount': {'emailAddress': 'a@x.com'},
          }),
        );

        final snapshot = await service.readSnapshot(paths);
        expect(snapshot.isSignedIn, isFalse);
        expect(snapshot.readFailure, contains('is not valid JSON'));
        expect(snapshot.readFailure, contains('.credentials.json'));

        await expectLater(
          service.capture(paths),
          throwsA(
            isA<ClaudeAuthException>().having(
              (e) => e.message,
              'message',
              contains('is not valid JSON'),
            ),
          ),
        );
      },
    );

    test('an absent credentials file is still simply signed out', () async {
      writeConfig(jsonEncode({'projects': {}}));
      final snapshot = await service.readSnapshot(paths);
      expect(snapshot.isSignedIn, isFalse);
      expect(snapshot.readFailure, isNull);
    });

    test('capture fails clearly when no email is present', () async {
      writeCreds({
        'claudeAiOauth': {'accessToken': 'tok'},
      });
      writeConfig(jsonEncode({'projects': {}}));
      expect(() => service.capture(paths), throwsA(isA<ClaudeAuthException>()));
    });

    test(
      'switch swaps token + identity, preserves the rest, and backs up',
      () async {
        // Existing install is account A, with an MCP token and case-differing keys.
        writeCreds({
          'claudeAiOauth': {'accessToken': 'A-token'},
          'mcpOAuth': {'server': 'keep-me'},
        });
        writeConfig(
          '{"g:/p": 1, "G:/p": 2, '
          '"oauthAccount": {"emailAddress": "a@x.com", "organizationUuid": "org-a"}, '
          '"projects": {"x": true}}',
        );

        final accountB = ClaudeAccount(
          id: 'b',
          email: 'b@y.com',
          claudeAiOauth: {'accessToken': 'B-token', 'subscriptionType': 'pro'},
          oauthAccount: {
            'emailAddress': 'b@y.com',
            'organizationUuid': 'org-b',
          },
          capturedAt: DateTime.utc(2026, 1, 1),
        );

        await service.switchTo(accountB, paths);

        final creds =
            jsonDecode(File(paths.credentialsFile).readAsStringSync()) as Map;
        expect((creds['claudeAiOauth'] as Map)['accessToken'], 'B-token');
        // MCP token preserved.
        expect((creds['mcpOAuth'] as Map)['server'], 'keep-me');

        final rawConfig = File(paths.configFile).readAsStringSync();
        final config = jsonDecode(rawConfig) as Map;
        expect((config['oauthAccount'] as Map)['emailAddress'], 'b@y.com');
        // Everything else preserved, including case-differing keys.
        expect(config['projects'], {'x': true});
        expect(rawConfig.contains('"g:/p": 1'), isTrue);
        expect(rawConfig.contains('"G:/p": 2'), isTrue);

        // One-time backups exist and hold the original contents.
        final credBak = File('${paths.credentialsFile}.karmashala.bak');
        final cfgBak = File('${paths.configFile}.karmashala.bak');
        expect(credBak.existsSync(), isTrue);
        expect(cfgBak.existsSync(), isTrue);
        expect(
          (jsonDecode(credBak.readAsStringSync())
              as Map)['claudeAiOauth']['accessToken'],
          'A-token',
        );
      },
    );

    test('readSnapshot returns signed-out when files are absent', () async {
      final snap = await service.readSnapshot(paths);
      expect(snap.isSignedIn, isFalse);
    });

    test('malformed config does not partially switch credentials', () async {
      writeCreds({
        'claudeAiOauth': {'accessToken': 'A-token'},
      });
      writeConfig('{not valid json');
      final accountB = ClaudeAccount(
        id: 'b',
        email: 'b@y.com',
        claudeAiOauth: {'accessToken': 'B-token'},
        oauthAccount: {'emailAddress': 'b@y.com'},
        capturedAt: DateTime.utc(2026, 1, 1),
      );

      await expectLater(
        service.switchTo(accountB, paths),
        throwsA(isA<ClaudeAuthException>()),
      );

      final creds = jsonDecode(File(paths.credentialsFile).readAsStringSync());
      expect((creds as Map)['claudeAiOauth']['accessToken'], 'A-token');
      expect(File(paths.configFile).readAsStringSync(), '{not valid json');
    });
  });
}

/// Where the credentials live, and how the paths to them are spelled.
///
/// Both halves of a plainly logged-in Mac account reporting itself signed out:
/// the config path was joined with the Windows separator, so
/// `/Users/me/.claude` became `/Users/me\.claude.json` and could not exist; and
/// even with that fixed, macOS keeps `claudeAiOauth` in the login Keychain and
/// writes no credentials file at all.
void _macOsCredentialsTests() {
  final now = DateTime.utc(2026, 9, 2, 12);

  ClaudeAuthService serviceReading(ClaudeKeychainRead read) =>
      ClaudeAuthService(
        ids: SequentialIdGenerator(),
        clock: FixedClock(now),
        readKeychain: () async => read,
      );

  ClaudeAuthService serviceHolding(String? secret) => serviceReading(
    secret == null
        ? const ClaudeKeychainRead.notFound()
        : ClaudeKeychainRead(ClaudeKeychainOutcome.found, secret: secret),
  );

  ClaudeAuthPaths pathsIn(Directory dir) => ClaudeAuthPaths(
    environmentId: 'windows',
    credentialsFile: '${dir.path}/.credentials.json',
    configFile: '${dir.path}/.claude.json',
    credentialsInKeychain: true,
  );

  test('the Keychain stands in for the credentials file', () async {
    final dir = await Directory.systemTemp.createTemp('claude-auth');
    addTearDown(() => dir.delete(recursive: true));
    final config = File('${dir.path}/.claude.json');
    await config.writeAsString(
      jsonEncode({
        'oauthAccount': {
          'emailAddress': 'me@x.com',
          'organizationName': 'My Org',
        },
      }),
    );
    final service = serviceHolding(
      jsonEncode({
        'claudeAiOauth': {
          'subscriptionType': 'max',
          'expiresAt': 1785221891296,
        },
      }),
    );

    final snapshot = await service.readSnapshot(
      ClaudeAuthPaths(
        environmentId: 'windows',
        // Deliberately absent: on macOS nothing writes it.
        credentialsFile: '${dir.path}/.claude/.credentials.json',
        configFile: config.path,
        credentialsInKeychain: true,
      ),
    );

    expect(snapshot.email, 'me@x.com');
    expect(
      snapshot.subscriptionType,
      'max',
      reason: 'the plan comes from the Keychain, not the missing file',
    );
  });

  test('an empty Keychain reads as signed out, not as a crash', () async {
    final dir = await Directory.systemTemp.createTemp('claude-auth');
    addTearDown(() => dir.delete(recursive: true));
    final service = serviceHolding(null);

    final snapshot = await service.readSnapshot(
      ClaudeAuthPaths(
        environmentId: 'windows',
        credentialsFile: '${dir.path}/.credentials.json',
        configFile: '${dir.path}/.claude.json',
        credentialsInKeychain: true,
      ),
    );

    expect(snapshot.email, isNull);
  });

  test('a denied prompt names the Keychain, not a signed-out account', () async {
    // The whole point. Folding a refusal into an empty snapshot told a user who
    // was plainly logged in to "Run `claude` in this environment to sign in",
    // over a credential that was sitting right there behind a *Deny* they had
    // clicked twelve minutes earlier.
    final dir = await Directory.systemTemp.createTemp('claude-auth');
    addTearDown(() => dir.delete(recursive: true));
    final service = serviceReading(
      ClaudeKeychainRead(
        ClaudeKeychainOutcome.refused,
        detail: 'User interaction is not allowed.',
        readAt: now.subtract(const Duration(minutes: 12)),
      ),
    );

    final snapshot = await service.readSnapshot(pathsIn(dir));

    expect(snapshot.isSignedIn, isFalse);
    expect(
      snapshot.keychainRefusal,
      allOf(
        contains('Keychain'),
        contains('User interaction is not allowed.'),
        // The age of the reading, because the memo holds a refusal for ten
        // minutes and what is on screen can be that old.
        contains('12m ago'),
        isNot(contains('signed in')),
      ),
    );
  });

  test('a Keychain that simply holds nothing says nothing extra', () async {
    // The other half of the distinction: an empty store *is* a signed-out
    // account, and a sentence about macOS refusing would be a lie about it.
    final dir = await Directory.systemTemp.createTemp('claude-auth');
    addTearDown(() => dir.delete(recursive: true));

    final snapshot = await serviceHolding(null).readSnapshot(pathsIn(dir));

    expect(snapshot.isSignedIn, isFalse);
    expect(snapshot.keychainRefusal, isNull);
  });

  test('capture says which of the two happened, and never names a file that '
      'macOS does not write', () async {
    final dir = await Directory.systemTemp.createTemp('claude-auth');
    addTearDown(() => dir.delete(recursive: true));

    await expectLater(
      serviceReading(
        ClaudeKeychainRead(
          ClaudeKeychainOutcome.refused,
          detail: 'User interaction is not allowed.',
          readAt: now.subtract(const Duration(minutes: 4)),
        ),
      ).capture(pathsIn(dir)),
      throwsA(
        isA<ClaudeAuthException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Keychain'), contains('4m ago')),
        ),
      ),
    );

    await expectLater(
      serviceHolding(null).capture(pathsIn(dir)),
      throwsA(
        isA<ClaudeAuthException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Nothing is stored under'),
            contains(ClaudeAuthService.keychainService),
            isNot(contains('.credentials.json')),
          ),
        ),
      ),
    );
  });

  test('an unstamped reading admits it does not know its own age', () {
    expect(
      claudeKeychainRefusalMessage(
        const ClaudeKeychainRead(ClaudeKeychainOutcome.refused),
        now: now,
      ),
      contains('at an unknown time'),
    );
  });

  test('switching is refused rather than half-applied', () async {
    // Rewriting the identity while the tokens stayed in the Keychain would
    // leave Claude authenticated as one account and labelled as another.
    final service = serviceHolding('{}');

    expect(
      () => service.switchTo(
        ClaudeAccount(
          id: 'a',
          email: 'a@x.com',
          claudeAiOauth: const {},
          oauthAccount: const {},
          capturedEnvironmentId: 'windows',
          capturedAt: DateTime.utc(2026),
        ),
        const ClaudeAuthPaths(
          environmentId: 'windows',
          credentialsFile: '/tmp/nope/.credentials.json',
          configFile: '/tmp/nope/.claude.json',
          credentialsInKeychain: true,
        ),
      ),
      throwsA(
        isA<ClaudeAuthException>().having(
          (e) => e.message,
          'message',
          contains('Keychain'),
        ),
      ),
    );
  });
}
