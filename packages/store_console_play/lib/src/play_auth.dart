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

/// The one authorised client every Play call goes through.
class PlayAuth {
  PlayAuth(this._account, http.Client base) : _base = _TimeoutClient(base);

  final PlayAccount _account;
  final http.Client _base;
  Future<AutoRefreshingAuthClient>? _client;

  /// Throws [StoreException] when the key is unusable or refused.
  Future<AutoRefreshingAuthClient> client() => _client ??= _open();

  Future<AutoRefreshingAuthClient> _open() async {
    try {
      final ServiceAccountCredentials credentials;
      try {
        credentials = ServiceAccountCredentials.fromJson(
          _account.serviceAccountJson,
        );
      } on Object {
        throw const StoreException(
          StoreFailure.auth,
          'That service-account key could not be read. Import the JSON key '
          'file again in Settings → Stores.',
        );
      }
      return await clientViaServiceAccount(
        credentials,
        playScopes,
        baseClient: _base,
      );
    } on Object catch (error) {
      // A failed attempt is not kept, so the next refresh tries again.
      _client = null;
      throw playFailure(error);
    }
  }

  /// Closes the authorised client and the transport under it.
  void close() {
    unawaited(
      _client?.then<void>((client) => client.close(), onError: (Object _) {}),
    );
    _base.close();
  }
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
