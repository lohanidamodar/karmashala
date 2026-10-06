import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:store_console_play/src/play_account.dart';
import 'package:store_console_play/src/play_auth.dart';
import 'package:test/test.dart';

/// The Play token, kept across clients: each refresh builds a new client,
/// and a token still good for a while is not exchanged again. No token
/// endpoint is called; test values only.
void main() {
  final t0 = DateTime.utc(2026, 10, 6, 8);
  late DateTime now;
  late int exchanged;
  late List<String?> bearers;
  late int status;

  const account = PlayAccount(
    serviceAccountJson:
        '{"client_email":"bot@example.iam.gserviceaccount.com"}',
  );

  Future<AccessCredentials> exchange(PlayAccount _, http.Client _) async {
    exchanged++;
    return AccessCredentials(
      AccessToken(
        'Bearer',
        'token-$exchanged',
        now.add(const Duration(hours: 1)),
      ),
      null,
      playScopes,
    );
  }

  PlayAuth auth(PlayTokens tokens) => PlayAuth(
    account,
    MockClient((request) async {
      bearers.add(request.headers['Authorization']);
      return http.Response('{}', status);
    }),
    tokens: tokens,
    now: () => now,
    exchange: exchange,
  );

  Future<void> call(PlayAuth auth) async {
    final client = await auth.client();
    await client.get(Uri.parse('https://example.com/api'));
    auth.close();
  }

  setUp(() {
    now = t0;
    exchanged = 0;
    bearers = [];
    status = 200;
  });

  test('a second client reuses the token the first was given', () async {
    final tokens = PlayTokens();
    await call(auth(tokens));
    now = now.add(const Duration(minutes: 20));
    await call(auth(tokens));
    expect(exchanged, 1);
    expect(bearers, ['Bearer token-1', 'Bearer token-1']);
  });

  test('a token near its end is exchanged again', () async {
    final tokens = PlayTokens();
    await call(auth(tokens));
    now = now.add(const Duration(minutes: 55));
    await call(auth(tokens));
    expect(exchanged, 2);
    expect(bearers.last, 'Bearer token-2');
  });

  test('a refused token is not offered again', () async {
    final tokens = PlayTokens();
    status = 401;
    await call(auth(tokens));
    status = 200;
    await call(auth(tokens));
    expect(exchanged, 2);
  });

  test('without a holder each client exchanges its own', () async {
    await call(auth(PlayTokens()));
    await call(auth(PlayTokens()));
    expect(exchanged, 2);
  });
}
