import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/agents/data/claude_auth_service.dart';
import 'package:karmashala/src/features/agents/domain/claude_account.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
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

    tearDown(() => dir.deleteSync(recursive: true));

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
