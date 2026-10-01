import 'dart:async';
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart'
    show ApiRequestError, DetailedApiRequestError;
import 'package:googleapis_auth/googleapis_auth.dart'
    show AccessDeniedException, ServerRequestFailedException;
import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

/// Which Google API a call went to, so a refusal names it and the remedy
/// names the grant that API needs.
enum PlayArea {
  /// Releases and tracks, through the Android Publisher API.
  publisher(_publisherApi),

  /// Reviews, through the Android Publisher API.
  reviews(_publisherApi),

  /// App discovery and vitals, through the Play Developer Reporting API.
  reporting('Google Play Developer Reporting API'),

  /// Ratings and installs, read out of the reports bucket in Cloud Storage.
  bucket('Cloud Storage API');

  const PlayArea(this.api);

  /// The API's name as Google Cloud Console lists it.
  final String api;
}

const String _publisherApi = 'Google Play Android Developer API';

/// The Play Console permission that lets a service account read app
/// information, vitals and the bulk reports.
const String _viewPermission =
    '"View app information and download bulk reports (read-only)"';

const Duration playCallTimeout = Duration(seconds: 30);

/// What a Google error body says in its structured fields: the reason codes,
/// the service and the project. Its free-text `message` is never read, since
/// it may quote a request.
class PlayErrorFacts {
  const PlayErrorFacts({this.reasons = const {}, this.service, this.project});

  /// Read from a decoded error body (`{"error": {...}}`), or from anything
  /// else, which says nothing.
  factory PlayErrorFacts.fromBody(Object? body) {
    final error = body is Map ? body['error'] : null;
    if (error is! Map) return const PlayErrorFacts();
    final reasons = <String>{};
    String? service;
    String? project;
    void reason(Object? value) {
      if (value is String && _code.hasMatch(value)) reasons.add(value);
    }

    reason(error['status']);
    for (final detail in _maps(error['errors'])) {
      reason(detail['reason']);
    }
    for (final detail in _maps(error['details'])) {
      final type = detail['@type'];
      if (type is! String || !type.endsWith('google.rpc.ErrorInfo')) continue;
      reason(detail['reason']);
      final metadata = detail['metadata'];
      if (metadata is! Map) continue;
      final named = metadata['service'];
      if (named is String && _service.hasMatch(named)) service ??= named;
      final consumer = metadata['consumer'];
      if (consumer is String) {
        project ??= _project.firstMatch(consumer)?.group(1);
      }
    }
    return PlayErrorFacts(reasons: reasons, service: service, project: project);
  }

  /// Read from a [DetailedApiRequestError]'s decoded body and its `errors`.
  factory PlayErrorFacts.fromError(DetailedApiRequestError error) {
    final fromBody = PlayErrorFacts.fromBody(error.jsonResponse);
    return PlayErrorFacts(
      reasons: {
        ...fromBody.reasons,
        for (final detail in error.errors)
          if (detail.reason case final String reason
              when _code.hasMatch(reason))
            reason,
      },
      service: fromBody.service,
      project: fromBody.project,
    );
  }

  /// `SERVICE_DISABLED`, `accessNotConfigured`, `PERMISSION_DENIED`, …: codes
  /// only, as Google sent them.
  final Set<String> reasons;

  /// The API's host, such as `playdeveloperreporting.googleapis.com`.
  final String? service;

  /// The number of the Google Cloud project the call was billed to: the
  /// service account's own.
  final String? project;

  bool has(Iterable<String> codes) {
    final lower = {for (final reason in reasons) reason.toLowerCase()};
    return codes.any((code) => lower.contains(code.toLowerCase()));
  }

  static final RegExp _code = RegExp(r'^[A-Za-z][A-Za-z0-9_.]{0,63}$');
  static final RegExp _service = RegExp(
    r'^[a-z0-9-]+(\.[a-z0-9-]+)*\.googleapis\.com$',
  );
  static final RegExp _project = RegExp(r'^projects/(\d{1,20})$');

  static Iterable<Map<Object?, Object?>> _maps(Object? list) =>
      list is List ? list.whereType<Map<Object?, Object?>>() : const [];
}

/// The one place a failure becomes a [StoreException]. The message is built
/// from the failure's kind and the error's structured fields alone, never its
/// text, which may quote a request.
StoreException playFailure(Object error, {PlayArea area = PlayArea.publisher}) {
  if (error is StoreException) return error;
  if (error is DetailedApiRequestError) {
    return playStatusFailure(
      error.status,
      area: area,
      facts: PlayErrorFacts.fromError(error),
    );
  }
  if (error is AccessDeniedException) return _refused;
  if (error is ServerRequestFailedException) {
    final status = error.statusCode;
    return status != null && status >= 500
        ? playStatusFailure(status, area: area)
        : _refused;
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is TlsException ||
      error is HttpException ||
      error is http.ClientException) {
    return const StoreException(
      StoreFailure.network,
      'Google Play could not be reached. Check the connection and refresh.',
    );
  }
  if (error is ApiRequestError) return _unreadable(null);
  return StoreException(
    StoreFailure.shape,
    'Google Play answered in a way this could not read '
    '(${error.runtimeType}).',
  );
}

/// What an HTTP status from any of the three Google APIs means to the user,
/// with [facts] from the error body naming the cause where Google gave one.
StoreException playStatusFailure(
  int? status, {
  PlayArea area = PlayArea.publisher,
  PlayErrorFacts facts = const PlayErrorFacts(),
}) {
  final bucket = area == PlayArea.bucket;
  return switch (status) {
    401 => _refused,
    // Google refusing the question, not the account: it says which rule in
    // its reason codes, which are all that is safe to repeat.
    400 => StoreException(
      StoreFailure.shape,
      'The ${area.api} refused the request as invalid (HTTP 400'
      '${facts.reasons.isEmpty ? '' : '; Google: ${(facts.reasons.toList()..sort()).join(', ')}'}). '
      'Refresh later; if it stays, it is likely Karmashala\'s fault — please '
      'report it.',
    ),
    403 => StoreException(StoreFailure.permission, _refusal(area, facts)),
    404 => StoreException(
      StoreFailure.notConfigured,
      bucket
          ? 'No report was found in that bucket. Check the bucket id in '
                'Settings → Stores.'
          : 'Google Play has no such app for this account. Check the '
                'package name in Settings → Stores.',
    ),
    429 => const StoreException(
      StoreFailure.rateLimited,
      'Google Play is limiting requests. Refresh again in a few minutes.',
    ),
    final int code when code >= 500 => const StoreException(
      StoreFailure.server,
      'Google Play had a problem of its own. Refresh again later.',
    ),
    _ => _unreadable(status),
  };
}

/// Why a 403 happened and what to do, from the structured reason codes.
String _refusal(PlayArea area, PlayErrorFacts facts) {
  final api = _apiNamed(facts.service) ?? area.api;
  final project = facts.project == null ? '' : ' (project ${facts.project})';
  final String text;
  if (facts.has(const ['SERVICE_DISABLED', 'accessNotConfigured'])) {
    text =
        'The $api is not enabled in the Google Cloud project of the service '
        'account$project. Enable it in Google Cloud Console → APIs & '
        'Services → Library for that project, wait a few minutes, then '
        'refresh.';
  } else if (facts.has(const ['projectNotLinked'])) {
    text =
        'Google says the Google Cloud project of the service account'
        '$project is not linked to this Play Console account. Link it in '
        'Play Console → Setup → API access where that page is offered, or '
        'invite the service account in Users and permissions, then refresh.';
  } else if (facts.has(const ['ACCESS_TOKEN_SCOPE_INSUFFICIENT'])) {
    text =
        'The $api refused the access scope Karmashala asked for. That is '
        "Karmashala's fault, not the account's; please report it.";
  } else if (facts.has(const [
    'PERMISSION_DENIED',
    'permissionDenied',
    'IAM_PERMISSION_DENIED',
    'forbidden',
    'insufficientPermissions',
  ])) {
    text = _permission(area, api);
  } else {
    text =
        'The $api refused the service account. It may not see this. Invite '
        'it in Play Console → Users and permissions with access to the app.';
  }
  return facts.reasons.isEmpty
      ? text
      : '$text (Google: ${(facts.reasons.toList()..sort()).join(', ')}.)';
}

/// The Play Console grant each API needs, worded as likely where Google does
/// not say which permission it checked.
String _permission(PlayArea area, String api) => switch (area) {
  PlayArea.publisher =>
    'The $api refused the service account for this app. In Play Console → '
        'Users and permissions, give it access to the app with at least '
        '$_viewPermission.',
  PlayArea.reviews =>
    'The $api refused to list reviews. In Play Console → Users and '
        'permissions, give the service account "Reply to reviews" for the '
        'app — likely the permission the reviews API checks.',
  PlayArea.reporting =>
    'The $api refused the service account. In Play Console → Users and '
        'permissions, give it $_viewPermission for the app, or for all apps '
        'so it can find them.',
  PlayArea.bucket =>
    'The service account may not read the reports bucket. In Play Console '
        '→ Users and permissions, give it access to the app\'s reports '
        '($_viewPermission).',
};

/// The Cloud Console name of an API Google named by host, when known.
String? _apiNamed(String? service) => switch (service) {
  'androidpublisher.googleapis.com' => _publisherApi,
  'playdeveloperreporting.googleapis.com' => PlayArea.reporting.api,
  'storage.googleapis.com' => PlayArea.bucket.api,
  'storage-api.googleapis.com' => 'Cloud Storage JSON API',
  null => null,
  final String host => 'API $host',
};

/// Runs [call] so that whatever it throws leaves as a [StoreException].
Future<T> playGuarded<T>(
  Future<T> Function() call, {
  PlayArea area = PlayArea.publisher,
}) async {
  try {
    return await call();
  } on Object catch (error) {
    throw playFailure(error, area: area);
  }
}

const StoreException _refused = StoreException(
  StoreFailure.auth,
  'Google refused the service-account key. Import a current key in '
  'Settings → Stores.',
);

StoreException _unreadable(int? status) => StoreException(
  StoreFailure.shape,
  status == null
      ? 'Google Play answered in a way this could not read.'
      : 'Google Play answered in a way this could not read (HTTP $status).',
);
