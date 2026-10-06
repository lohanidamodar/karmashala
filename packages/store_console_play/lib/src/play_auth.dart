import 'dart:async';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

import 'play_account.dart';
import 'play_errors.dart';

const List<String> playScopes = [
  'https://www.googleapis.com/auth/androidpublisher',
  'https://www.googleapis.com/auth/playdeveloperreporting',
  'https://www.googleapis.com/auth/devstorage.read_only',
];

/// Trades a service account's key for an access token.
typedef PlayTokenExchange =
    Future<AccessCredentials> Function(PlayAccount account, http.Client base);

/// The access token, kept by whoever outlives one client: a token is good
/// for an hour, and each refresh builds a new client. A new key needs a new
/// holder.
class PlayTokens {
  /// A token with less than this left is exchanged again, so none expires
  /// while a refresh is using it.
  static const Duration margin = Duration(minutes: 10);

  AccessCredentials? _held;

  AccessCredentials? _fresh(DateTime now) {
    final held = _held;
    if (held == null) return null;
    return held.accessToken.expiry.isAfter(now.toUtc().add(margin))
        ? held
        : null;
  }
}

/// The one authorised client every Play call goes through.
class PlayAuth {
  PlayAuth(
    this._account,
    http.Client base, {
    PlayTokens? tokens,
    DateTime Function()? now,
    PlayTokenExchange? exchange,
  }) : _base = _TimeoutClient(base),
       _tokens = tokens ?? PlayTokens(),
       _now = now ?? DateTime.now,
       _exchange = exchange ?? _serviceAccountExchange;

  final PlayAccount _account;
  final http.Client _base;
  final PlayTokens _tokens;
  final DateTime Function() _now;
  final PlayTokenExchange _exchange;
  Future<http.Client>? _client;

  /// Throws [StoreException] when the key is unusable or refused.
  Future<http.Client> client() => _client ??= _open();

  Future<http.Client> _open() async {
    try {
      final credentials =
          _tokens._fresh(_now()) ?? await _exchange(_account, _base);
      _tokens._held = credentials;
      return _RefusalClient(authenticatedClient(_base, credentials), () {
        if (identical(_tokens._held, credentials)) _tokens._held = null;
      });
    } on Object catch (error) {
      // A failed attempt is not kept, so the next refresh tries again.
      _client = null;
      throw playFailure(error);
    }
  }

  static Future<AccessCredentials> _serviceAccountExchange(
    PlayAccount account,
    http.Client base,
  ) {
    final ServiceAccountCredentials credentials;
    try {
      credentials = ServiceAccountCredentials.fromJson(
        account.serviceAccountJson,
      );
    } on Object {
      throw const StoreException(
        StoreFailure.auth,
        'That service-account key could not be read. Import the JSON key '
        'file again in Settings → Stores.',
      );
    }
    return obtainAccessCredentialsViaServiceAccount(
      credentials,
      playScopes,
      base,
    );
  }

  /// Closes the authorised client and the transport under it.
  void close() {
    unawaited(
      _client?.then<void>((client) => client.close(), onError: (Object _) {}),
    );
    _base.close();
  }
}

/// Forgets the kept token when Google answers that it is not good, so the
/// next client does not offer it again.
class _RefusalClient extends http.BaseClient {
  _RefusalClient(this._inner, this._refused);

  final http.Client _inner;
  final void Function() _refused;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode == 401) _refused();
    return response;
  }

  @override
  void close() => _inner.close();
}

/// Gives every request, and every gap in its response, the same deadline.
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request).timeout(playCallTimeout);
    return http.StreamedResponse(
      response.stream.timeout(playCallTimeout),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
