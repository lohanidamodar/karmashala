import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

typedef JsonMap = Map<String, Object?>;

const appleRequestTimeout = Duration(seconds: 30);

/// Every request the client makes, with each failure turned into a
/// [StoreException].
class AppleHttp {
  AppleHttp(this._client, this._token, this._now);

  final http.Client _client;
  final String Function() _token;
  final DateTime Function() _now;

  /// [what] names the thing being read, for the message. [role] is the role
  /// a 403 most likely means is missing. Null only for a 404 with
  /// [absentOn404].
  Future<http.Response?> get(
    Uri uri, {
    required String what,
    bool authorized = true,
    String accept = 'application/json',
    String? role,
    bool absentOn404 = false,
    Duration timeout = appleRequestTimeout,
  }) async {
    final token = authorized ? _token() : null;
    final service = authorized ? 'App Store Connect' : 'The App Store';
    final http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: {
              'Accept': accept,
              if (token != null) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(timeout);
    } on TimeoutException {
      throw StoreException(
        StoreFailure.network,
        '$service did not answer within '
        '${timeout.inSeconds} seconds. Try again.',
      );
    } on Exception {
      // The error's text can carry the request URL, so it is not passed on.
      throw StoreException(
        StoreFailure.network,
        '$service could not be reached. Check the connection and try again.',
      );
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) return response;
    if (status == 404 && absentOn404) return null;

    var detail = _errorDetail(response);
    if (detail != null && token != null && detail.contains(token)) {
      detail = null;
    }
    final says = detail == null ? '' : ' Apple says: $detail';
    switch (status) {
      case 401:
        throw const StoreException(
          StoreFailure.auth,
          'App Store Connect refused the key. Check the key ID and issuer '
          'ID, or whether the key was revoked.',
        );
      case 403:
        final needs = role == null ? '' : ' It needs the $role role.';
        throw StoreException(
          StoreFailure.permission,
          'This key may not read $what.$needs$says',
        );
      case 429:
        throw StoreException(
          StoreFailure.rateLimited,
          '$service is limiting how often this key may ask. Try again later.',
          retryAfter: _retryAfter(response),
        );
    }
    if (status >= 500) {
      throw StoreException(
        StoreFailure.server,
        '$service had a problem of its own (HTTP $status). Try again later.',
      );
    }
    throw StoreException(
      StoreFailure.shape,
      '$service did not accept the request for $what (HTTP $status).$says',
    );
  }

  Future<JsonMap> getJson(
    Uri uri, {
    required String what,
    bool authorized = true,
    String? role,
    Duration timeout = appleRequestTimeout,
  }) async {
    final response = await get(
      uri,
      what: what,
      authorized: authorized,
      role: role,
      timeout: timeout,
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response!.bodyBytes));
    } on FormatException {
      throw shapeFailure(what);
    }
    if (decoded is Map) return decoded.cast<String, Object?>();
    throw shapeFailure(what);
  }

  void close() => _client.close();

  Duration? _retryAfter(http.Response response) {
    final header = response.headers['retry-after']?.trim();
    if (header == null || header.isEmpty) return null;
    final seconds = int.tryParse(header);
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    try {
      final wait = HttpDate.parse(header).difference(_now());
      return wait.isNegative ? Duration.zero : wait;
    } on HttpException {
      return null;
    }
  }
}

StoreException shapeFailure(String what) => StoreException(
  StoreFailure.shape,
  'The App Store answered about $what in a form this version does not read.',
);

String? _errorDetail(http.Response response) {
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return null;
    final errors = decoded['errors'];
    if (errors is! List || errors.isEmpty) return null;
    final first = errors.first;
    if (first is! Map) return null;
    final detail = first['detail'] ?? first['title'];
    return detail is String && detail.trim().isNotEmpty ? detail.trim() : null;
  } on FormatException {
    return null;
  }
}
