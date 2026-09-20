import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/data/claude_auth_service.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';
import '../support/temp_directory.dart';

/// Stands in for the real access token. `hasUsableLogin` answers a bool, so
/// this must never come back out of anything it touches.
const _token = 'sk-ant-oat-the-value-nothing-may-print';

void main() {
  group('hasUsableLogin', () {
    late Directory dir;
    late ClaudeAuthPaths paths;
    late ClaudeAuthService service;
    final now = DateTime.utc(2026, 1, 1);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('claude_login_presence');
      paths = ClaudeAuthPaths(
        environmentId: 'test',
        credentialsFile: '${dir.path}/.credentials.json',
        configFile: '${dir.path}/.claude.json',
      );
      service = ClaudeAuthService(
        ids: SequentialIdGenerator(),
        clock: FixedClock(now),
      );
    });

    tearDown(() => removeTempDirectory(dir));

    void signIn({int? expiresAt}) {
      File(paths.credentialsFile).writeAsStringSync(
        jsonEncode({
          'claudeAiOauth': {
            'accessToken': _token,
            'refreshToken': _token,
            'expiresAt': ?expiresAt,
          },
        }),
      );
      File(paths.configFile).writeAsStringSync(
        jsonEncode({
          'oauthAccount': {'emailAddress': 'me@x.com'},
        }),
      );
    }

    test('a login whose token has not lapsed is usable', () async {
      signIn(
        expiresAt: now.add(const Duration(hours: 8)).millisecondsSinceEpoch,
      );

      expect(await service.hasUsableLogin(paths), isTrue);
    });

    test('a login with no recorded expiry is usable', () async {
      signIn();

      expect(await service.hasUsableLogin(paths), isTrue);
    });

    test('a lapsed token is not something a launch may rely on', () async {
      signIn(
        expiresAt: now
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );

      expect(await service.hasUsableLogin(paths), isFalse);
    });

    test('nobody signed in here', () async {
      expect(await service.hasUsableLogin(paths), isFalse);
    });

    test('credentials but no identity is not a login', () async {
      File(paths.credentialsFile).writeAsStringSync(
        jsonEncode({
          'claudeAiOauth': {'accessToken': _token},
        }),
      );

      expect(await service.hasUsableLogin(paths), isFalse);
    });

    test('a credentials file we could not read is not a login', () async {
      File(paths.credentialsFile).writeAsStringSync('{"claudeAiOauth": ');
      File(paths.configFile).writeAsStringSync(
        jsonEncode({
          'oauthAccount': {'emailAddress': 'me@x.com'},
        }),
      );

      expect(await service.hasUsableLogin(paths), isFalse);
    });
  });
}
