import 'dart:convert';

import 'package:agent_cli/usage.dart';
import 'package:test/test.dart';

/// A [RemoteHome] that keeps what was written, so a test can read it back.
class _FakeHome implements RemoteHome {
  _FakeHome({this.homePath = '/home/dlohani', Map<String, String>? existing})
    : files = {...?existing};

  @override
  final String homePath;

  final Map<String, String> files;

  /// Paths written with owner-only permission, in order.
  final List<String> private = [];

  @override
  Future<String?> read(String path) async => files[path];

  @override
  Future<void> write(String path, String contents) async =>
      files[path] = contents;

  @override
  Future<void> writePrivate(String path, String contents) async {
    private.add(path);
    files[path] = contents;
  }
}

void main() {
  final account = ClaudeAccount(
    id: 'a1',
    email: 'me@example.com',
    claudeAiOauth: const {'accessToken': 'tok', 'refreshToken': 'ref'},
    oauthAccount: const {'emailAddress': 'me@example.com'},
    capturedAt: DateTime.utc(2026),
  );

  group('pushing a Claude account', () {
    test('writes the token owner-only, and the identity beside it', () async {
      final home = _FakeHome();

      final written = await pushClaudeAccount(account, home);

      expect(written, [
        '/home/dlohani/.claude/.credentials.json',
        '/home/dlohani/.claude.json',
      ]);
      // The token is a secret; the identity record is not.
      expect(home.private, ['/home/dlohani/.claude/.credentials.json']);
      expect(
        jsonDecode(home.files['/home/dlohani/.claude/.credentials.json']!),
        {
          'claudeAiOauth': {'accessToken': 'tok', 'refreshToken': 'ref'},
        },
      );
    });

    test('keeps every other key in an existing credentials file', () async {
      // An MCP server's token lives here too, and copying an account must not
      // sign the remote out of it.
      final home = _FakeHome(
        existing: {
          '/home/dlohani/.claude/.credentials.json': jsonEncode({
            'claudeAiOauth': {'accessToken': 'old'},
            'mcpOAuth': {'server': 'keep-me'},
          }),
        },
      );

      await pushClaudeAccount(account, home);

      final after = jsonDecode(
        home.files['/home/dlohani/.claude/.credentials.json']!,
      );
      expect(after['claudeAiOauth'], {
        'accessToken': 'tok',
        'refreshToken': 'ref',
      });
      expect(after['mcpOAuth'], {'server': 'keep-me'});
    });

    test('splices the config rather than rewriting it', () async {
      // `.claude.json` can hold keys differing only by case, which a
      // decode-then-encode would collapse. The bytes around the spliced key
      // have to come through untouched.
      const raw =
          '{"oauthAccount":{"emailAddress":"old@example.com"},'
          '"projects":{"g:/x":1,"G:/x":2}}';
      final home = _FakeHome(
        existing: {'/home/dlohani/.claude.json': raw},
      );

      await pushClaudeAccount(account, home);

      final after = home.files['/home/dlohani/.claude.json']!;
      expect(after, contains('"g:/x":1'));
      expect(after, contains('"G:/x":2'));
      expect(after, contains('"emailAddress":"me@example.com"'));
      expect(after, isNot(contains('old@example.com')));
    });

    test('an account captured without an identity writes only the token', () async {
      final home = _FakeHome();

      final written = await pushClaudeAccount(
        ClaudeAccount(
          id: 'a2',
          email: 'me@example.com',
          claudeAiOauth: const {'accessToken': 'tok'},
          capturedAt: DateTime.utc(2026),
        ),
        home,
      );

      expect(written, ['/home/dlohani/.claude/.credentials.json']);
      expect(home.files.containsKey('/home/dlohani/.claude.json'), isFalse);
    });
  });

  group('pushing a Codex account', () {
    test('writes auth.json owner-only, whole', () async {
      final home = _FakeHome();

      final written = await pushCodexAccount(
        CodexAccount(
          id: 'c1',
          accountId: 'acct',
          auth: const {'tokens': {'access_token': 'tok'}},
          capturedAt: DateTime.utc(2026),
        ),
        home,
      );

      expect(written, ['/home/dlohani/.codex/auth.json']);
      expect(home.private, written);
      expect(jsonDecode(home.files.values.single), {
        'tokens': {'access_token': 'tok'},
      });
    });
  });

  group('pushing an Antigravity token', () {
    test('writes the token file owner-only, verbatim', () async {
      final home = _FakeHome();
      const token = '{"auth_method":"oauth","token":"t","id_token":"i"}';

      final written = await pushAntigravityToken(token, home);

      expect(written, [
        '/home/dlohani/.gemini/antigravity-cli/antigravity-oauth-token',
      ]);
      expect(home.private, written);
      expect(home.files.values.single, token);
    });
  });
}
