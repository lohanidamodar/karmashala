import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/forwarded_runs.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'agent_work_support.dart';

/// **Who is signed in, and switching who is — by the server** (slice 2a),
/// in a temporary home with a fake Keychain: identity crosses, tokens never
/// do — not in an answer, not in a change, not in a refusal. Codex's
/// `auth.json` carries the full capture → switch → file round trip on every
/// platform; Claude's credential is in the Keychain on a Mac (a switch is
/// refused there, in words) and in a file elsewhere.
void main() {
  final now = DateTime.utc(2026, 9, 26, 12);
  final expiresAt = now.add(const Duration(hours: 6));

  late Directory home;
  late MutableClock clock;
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  late ServerAgentWork work;
  late int keychainReads;
  late String? keychainSecret;
  var nextId = 0;

  // The secrets. Every one of them must stay at the server.
  const codexAccessA = 'codex-access-A-SECRET';
  const codexRefreshA = 'codex-refresh-A-SECRET';
  const codexAccessB = 'codex-access-B-SECRET';
  const codexRefreshB = 'codex-refresh-B-SECRET';
  const claudeAccess = 'claude-access-SECRET';
  const claudeRefresh = 'claude-refresh-SECRET';

  String jwt(Map<String, Object?> claims) =>
      'eyJhbGciOiJub25lIn0.'
      '${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}'
      '.sig';

  String idToken(String email, String account) => jwt({
    'email': email,
    'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'https://api.openai.com/auth': {
      'chatgpt_account_id': account,
      'chatgpt_plan_type': 'plus',
    },
  });

  final secrets = [
    codexAccessA,
    codexRefreshA,
    codexAccessB,
    codexRefreshB,
    claudeAccess,
    claudeRefresh,
    idToken('a@example.com', 'acct-A'),
    idToken('b@example.com', 'acct-B'),
  ];

  Map<String, Object?> codexAuth(
    String email,
    String account,
    String access,
    String refresh, {
    String lastRefresh = '2026-09-26T00:00:00Z',
  }) => {
    'OPENAI_API_KEY': null,
    'tokens': {
      'id_token': idToken(email, account),
      'access_token': access,
      'refresh_token': refresh,
      'account_id': account,
    },
    'last_refresh': lastRefresh,
  };

  File codexFile() => File(p.join(home.path, '.codex', 'auth.json'));
  File codexBackup() =>
      File(p.join(home.path, '.codex', 'auth.json.karmashala.bak'));

  void writeCodex(Map<String, Object?> auth) {
    codexFile()
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(auth));
  }

  Map<String, Object?> readCodex() =>
      (jsonDecode(codexFile().readAsStringSync()) as Map)
          .cast<String, Object?>();

  final claudeOauth = {
    'accessToken': claudeAccess,
    'refreshToken': claudeRefresh,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'subscriptionType': 'max',
  };

  File claudeCredentials() =>
      File(p.join(home.path, '.claude', '.credentials.json'));

  void signInClaude() {
    // Where Claude Code keeps the token: the Keychain on a Mac, a file
    // elsewhere. Both are written; the platform decides which is read.
    keychainSecret = jsonEncode({'claudeAiOauth': claudeOauth});
    claudeCredentials()
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'claudeAiOauth': claudeOauth}));
    File(p.join(home.path, '.claude.json')).writeAsStringSync(
      jsonEncode({
        'numStartups': 3,
        'oauthAccount': {
          'emailAddress': 'claude@example.com',
          'organizationUuid': 'org-1',
          'organizationName': 'Org',
          'accountUuid': 'uuid-1',
        },
      }),
    );
  }

  AgentInstallation row(String id, String agentId) => AgentInstallation(
    id: id,
    agentId: agentId,
    executable: EnvironmentPath(
      environmentId: localHostEnvironmentId,
      path: '/usr/local/bin/$id',
    ),
    createdAt: now,
  );

  List<DataChange> toldChanges() => [for (final b in told) ...b.changes];
  String toldText() => jsonEncode([for (final b in told) b.toJson()]);

  void expectNoSecret(String text, {String? reason}) {
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)), reason: reason);
    }
  }

  Future<Map<String, Object?>> ask(
    String kind,
    Map<String, Object?> arguments,
  ) async {
    final answer = await app.handleJson({
      'id': ++nextId,
      'kind': kind,
      'arguments': arguments,
    });
    expectNoSecret(jsonEncode(answer), reason: '$kind answered a secret');
    return answer;
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('ks-accounts-home');
    clock = MutableClock(now);
    keychainReads = 0;
    keychainSecret = null;
    db = AppDatabase.memory();
    service = DataService(db, clock: () => clock.now);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    service.ensureEnvironment(localHostEnvironment(now));
    service.reconcileProbe(
      environmentId: localHostEnvironmentId,
      readAt: now,
      found: [
        row('codex1', AgentIds.codex),
        row('claude1', AgentIds.claudeCode),
        row('gravity1', AgentIds.antigravity),
      ],
      probed: const {},
      readings: const {},
    );
    work = ServerAgentWork(
      data: service,
      runs: ForwardedRuns(),
      clock: clock,
      ids: CountingIds('saved'),
      hostEnvironment: {'HOME': home.path, 'USERPROFILE': home.path},
      usageService: (_) => ScriptedUsageService(
        clock: clock,
        answer: (_) => throw UsageException('not in this test'),
      ),
      claudeAuth: ClaudeAuthService(
        ids: CountingIds('claude'),
        clock: clock,
        readKeychain: () async {
          keychainReads++;
          final secret = keychainSecret;
          return secret == null
              ? const ClaudeKeychainRead.notFound()
              : ClaudeKeychainRead(ClaudeKeychainOutcome.found, secret: secret);
        },
      ),
      onItsOwn: false,
    )..attach();
    told.clear();
  });

  tearDown(() {
    work.stop();
    db.close();
    home.deleteSync(recursive: true);
  });

  group('Codex (an auth file)', () {
    test('accounts.current answers who, never the token', () async {
      writeCodex(
        codexAuth('a@example.com', 'acct-A', codexAccessA, codexRefreshA),
      );
      final answer = await ask(AccountsCurrent.name, {
        'installationId': 'codex1',
      });
      final signIn =
          AgentSignIn.fromJson((answer['result'] as Map).cast())
              as OpenAiSignIn;
      expect(signIn.snapshot.accountId, 'acct-A');
      expect(signIn.snapshot.email, 'a@example.com');
      expect(signIn.snapshot.planType, 'plus');
      expect(
        signIn.snapshot.accessTokenExpiresAt,
        expiresAt.toUtc().copyWith(millisecond: 0, microsecond: 0),
      );
    });

    test('signed out is a sign-in without an account, not a refusal', () async {
      final answer = await ask(AccountsCurrent.name, {
        'installationId': 'codex1',
      });
      final signIn =
          AgentSignIn.fromJson((answer['result'] as Map).cast())
              as OpenAiSignIn;
      expect(signIn.snapshot.accountId, isNull);
    });

    test('accounts.capture saves the account, answers its id, and tells it '
        'without credentials', () async {
      writeCodex(
        codexAuth('a@example.com', 'acct-A', codexAccessA, codexRefreshA),
      );
      final answer = await ask(AccountsCapture.name, {
        'installationId': 'codex1',
      });
      final id = answer['result'] as String;
      expect(
        toldChanges().whereType<CodexAccountChanged>().single.account.id,
        id,
      );
      expectNoSecret(toldText(), reason: 'a change carried a secret');
      // The server alone holds the bundle.
      final saved = service.codexAccount(id);
      expect(saved.accountId, 'acct-A');
      expect((saved.auth['tokens'] as Map)['access_token'], codexAccessA);
      final listed = app.handle(const AgentsList()).value.codexAccounts.single;
      expect(listed.auth, isEmpty);

      // The same account again keeps its id.
      final again = await ask(AccountsCapture.name, {
        'installationId': 'codex1',
      });
      expect(again['result'], id);
    });

    test('accounts.switch writes the saved tokens, backs the old file up once, '
        'and captured the outgoing account first', () async {
      writeCodex(
        codexAuth('a@example.com', 'acct-A', codexAccessA, codexRefreshA),
      );
      final idA =
          (await ask(AccountsCapture.name, {
                'installationId': 'codex1',
              }))['result']
              as String;

      // Signed in as B, never captured.
      final asB = codexAuth(
        'b@example.com',
        'acct-B',
        codexAccessB,
        codexRefreshB,
        lastRefresh: 'B-was-here',
      );
      writeCodex(asB);
      final originalB = codexFile().readAsStringSync();
      told.clear();

      final switched = await ask(AccountsSwitch.name, {
        'installationId': 'codex1',
        'accountId': idA,
      });
      expect(switched.containsKey('refusal'), isFalse, reason: '$switched');

      final file = readCodex();
      final tokens = (file['tokens'] as Map).cast<String, Object?>();
      expect(tokens['access_token'], codexAccessA);
      expect(tokens['refresh_token'], codexRefreshA);
      expect(tokens['account_id'], 'acct-A');
      expect(file['last_refresh'], 'B-was-here', reason: 'only tokens swap');
      expect(codexBackup().readAsStringSync(), originalB);

      // B was captured before it was replaced, so it can be switched back to.
      final accounts = app.handle(const AgentsList()).value.codexAccounts;
      expect(accounts.map((a) => a.accountId).toSet(), {'acct-A', 'acct-B'});
      final idB = accounts.firstWhere((a) => a.accountId == 'acct-B').id;
      expect(
        (service.codexAccount(idB).auth['tokens'] as Map)['access_token'],
        codexAccessB,
      );
      expect(toldChanges().whereType<CodexAccountChanged>(), isNotEmpty);
      expectNoSecret(toldText(), reason: 'a change carried a secret');

      // Back to B: the backup is the first one, kept.
      await ask(AccountsSwitch.name, {
        'installationId': 'codex1',
        'accountId': idB,
      });
      expect(((readCodex()['tokens'] as Map))['access_token'], codexAccessB);
      expect(codexBackup().readAsStringSync(), originalB);

      final current = await ask(AccountsCurrent.name, {
        'installationId': 'codex1',
      });
      expect(((current['result'] as Map))['accountId'], 'acct-B');
    });

    test('capturing with nobody signed in is refused in words', () async {
      final answer = await ask(AccountsCapture.name, {
        'installationId': 'codex1',
      });
      expect((answer['refusal'] as Map)['code'], DataRefusalCode.failed.name);
      expect((answer['refusal'] as Map)['message'], contains('auth.json'));
    });
  });

  group('Claude (Keychain on a Mac, a file elsewhere)', () {
    final onMac = Platform.isMacOS;

    test(
      'accounts.current answers who and whether the login is usable',
      () async {
        signInClaude();
        final answer = await ask(AccountsCurrent.name, {
          'installationId': 'claude1',
        });
        final signIn =
            AgentSignIn.fromJson((answer['result'] as Map).cast())
                as AnthropicSignIn;
        expect(signIn.snapshot.email, 'claude@example.com');
        expect(signIn.snapshot.organizationName, 'Org');
        expect(signIn.snapshot.subscriptionType, 'max');
        expect(signIn.usableLogin, isTrue);
        expect(keychainReads, onMac ? greaterThan(0) : 0);

        clock.advance(const Duration(hours: 7));
        final lapsed = await ask(AccountsCurrent.name, {
          'installationId': 'claude1',
        });
        expect((lapsed['result'] as Map)['usableLogin'], isFalse);
      },
    );

    test(
      'accounts.capture saves it and tells it without credentials',
      () async {
        signInClaude();
        final answer = await ask(AccountsCapture.name, {
          'installationId': 'claude1',
        });
        final id = answer['result'] as String;
        expect(
          toldChanges().whereType<ClaudeAccountChanged>().single.account.id,
          id,
        );
        expectNoSecret(toldText(), reason: 'a change carried a secret');
        expect(toldText(), isNot(contains('uuid-1')));
        expect(
          service.claudeAccount(id).claudeAiOauth['accessToken'],
          claudeAccess,
        );
      },
    );

    test(
      onMac
          ? 'a switch on a Mac is refused in words, and nothing is written'
          : 'a switch writes the saved token into the credentials file',
      () async {
        signInClaude();
        final id =
            (await ask(AccountsCapture.name, {
                  'installationId': 'claude1',
                }))['result']
                as String;
        // Someone else signs in.
        const otherOauth = {'accessToken': 'other-token', 'expiresAt': 1};
        keychainSecret = jsonEncode({'claudeAiOauth': otherOauth});
        claudeCredentials().writeAsStringSync(
          jsonEncode({'claudeAiOauth': otherOauth}),
        );
        final before = claudeCredentials().readAsStringSync();

        final answer = await ask(AccountsSwitch.name, {
          'installationId': 'claude1',
          'accountId': id,
        });
        if (onMac) {
          final refusal = (answer['refusal'] as Map).cast<String, Object?>();
          expect(refusal['code'], DataRefusalCode.failed.name);
          expect(refusal['message'], contains('macOS'));
          expect(claudeCredentials().readAsStringSync(), before);
        } else {
          expect(answer.containsKey('refusal'), isFalse, reason: '$answer');
          final written =
              jsonDecode(claudeCredentials().readAsStringSync()) as Map;
          expect(
            (written['claudeAiOauth'] as Map)['accessToken'],
            claudeAccess,
          );
        }
      },
    );
  });

  group('refusals carry no secret', () {
    setUp(() {
      writeCodex(
        codexAuth('a@example.com', 'acct-A', codexAccessA, codexRefreshA),
      );
      signInClaude();
    });

    test('an unknown installation is notFound', () async {
      for (final kind in [AccountsCurrent.name, AccountsCapture.name]) {
        final answer = await ask(kind, {'installationId': 'ghost'});
        expect(
          (answer['refusal'] as Map)['code'],
          DataRefusalCode.notFound.name,
          reason: kind,
        );
      }
      final answer = await ask(AccountsSwitch.name, {
        'installationId': 'ghost',
        'accountId': 'x',
      });
      expect((answer['refusal'] as Map)['code'], DataRefusalCode.notFound.name);
    });

    test('an agent with no accounts to switch is invalid; its sign-in is '
        'none', () async {
      final current = await ask(AccountsCurrent.name, {
        'installationId': 'gravity1',
      });
      expect(
        AgentSignIn.fromJson((current['result'] as Map).cast()),
        isA<NoSignIn>(),
      );
      for (final answer in [
        await ask(AccountsCapture.name, {'installationId': 'gravity1'}),
        await ask(AccountsSwitch.name, {
          'installationId': 'gravity1',
          'accountId': 'x',
        }),
      ]) {
        final refusal = (answer['refusal'] as Map).cast<String, Object?>();
        expect(refusal['code'], DataRefusalCode.invalid.name);
        expect(refusal['message'], contains('no accounts to switch'));
      }
    });

    test(
      'a saved account nobody has is notFound, and the file stands',
      () async {
        final before = codexFile().readAsStringSync();
        final answer = await ask(AccountsSwitch.name, {
          'installationId': 'codex1',
          'accountId': 'ghost',
        });
        expect(
          (answer['refusal'] as Map)['code'],
          DataRefusalCode.notFound.name,
        );
        expect(codexFile().readAsStringSync(), before);
        expect(codexBackup().existsSync(), isFalse);
      },
    );
  });
}
