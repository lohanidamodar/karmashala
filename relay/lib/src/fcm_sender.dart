/// The real [PushDelivery]: Firebase Cloud Messaging's HTTP v1 API. Built only
/// by the relay binary, only when [kServiceAccountEnvVar] names a service
/// account; nothing else in the relay touches Google.
library;

import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:http/http.dart' as http;

import 'push_delivery.dart';

/// Environment variable naming the service-account JSON file's path. Unset
/// (the default) leaves push delivery unconfigured: `/v1/push` still
/// registers tokens but answers push requests with 503.
const String kServiceAccountEnvVar = 'RELAY_FCM_SERVICE_ACCOUNT';

/// Sends opaque payloads through FCM HTTP v1 as data-only messages, so the
/// phone — never Google, never the relay — decrypts and renders the text.
class FcmHttpV1Sender implements PushDelivery {
  /// Parses only [projectId]; the credential is read on first use, so building
  /// this signs nothing and touches no network.
  FcmHttpV1Sender.fromServiceAccountJson(String json)
    : _credentialsJson = json,
      projectId = _projectIdOf(json);

  /// Builds a sender from [environment], or null when the variable is unset
  /// or empty — the default, and what every test environment is.
  static FcmHttpV1Sender? fromEnvironment(
    Map<String, String> environment, {
    String Function(String path)? readFile,
  }) {
    final path = environment[kServiceAccountEnvVar];
    if (path == null || path.trim().isEmpty) return null;
    final read = readFile ?? (p) => File(p).readAsStringSync();
    return FcmHttpV1Sender.fromServiceAccountJson(read(path.trim()));
  }

  static const String _scope =
      'https://www.googleapis.com/auth/firebase.messaging';

  /// The Firebase project the messages are sent under.
  final String projectId;

  final String _credentialsJson;
  auth.AutoRefreshingAuthClient? _client;

  static String _projectIdOf(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const FormatException('service account is not JSON');
    }
    final projectId = decoded is Map<String, Object?>
        ? decoded['project_id']
        : null;
    if (projectId is! String || projectId.isEmpty) {
      throw const FormatException('service account names no project_id');
    }
    return projectId;
  }

  /// The FCM v1 message for one push: data-only (no `notification` block —
  /// the text lives inside the ciphertext), high priority so a dozing phone
  /// is woken to decrypt it.
  static Map<String, Object?> messageFor({
    required String token,
    required String payload,
  }) => {
    'message': {
      'token': token,
      'data': {'payload': payload},
      'android': {'priority': 'HIGH'},
      'apns': {
        'headers': {'apns-priority': '10'},
      },
    },
  };

  Uri get _endpoint =>
      Uri.https('fcm.googleapis.com', '/v1/projects/$projectId/messages:send');

  Future<http.Client> _authedClient() async =>
      _client ??= await auth.clientViaServiceAccount(
        auth.ServiceAccountCredentials.fromJson(_credentialsJson),
        const [_scope],
      );

  @override
  Future<void> deliver({
    required String token,
    required String platform,
    required String payload,
  }) async {
    final http.Response response;
    try {
      final client = await _authedClient();
      response = await client.post(
        _endpoint,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(messageFor(token: token, payload: payload)),
      );
    } on Object catch (error) {
      throw PushDeliveryException('fcm request failed: ${error.runtimeType}');
    }
    if (response.statusCode == 404 || response.statusCode == 410) {
      // UNREGISTERED: the app is gone from that device.
      throw const PushTokenGoneException();
    }
    if (response.statusCode >= 300) {
      throw PushDeliveryException('fcm answered ${response.statusCode}');
    }
  }

  void close() {
    _client?.close();
    _client = null;
  }
}
