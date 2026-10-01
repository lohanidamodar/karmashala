import 'dart:async';
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart'
    show ApiRequestError, DetailedApiRequestError;
import 'package:googleapis_auth/googleapis_auth.dart'
    show AccessDeniedException, ServerRequestFailedException;
import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

/// Which grant a refusal is about, so the remedy names the right one.
enum PlayArea { console, bucket }

const Duration playCallTimeout = Duration(seconds: 30);

/// The one place a failure becomes a [StoreException]. The message is built
/// from the failure's kind alone, never its text, which may quote a request.
StoreException playFailure(Object error, {PlayArea area = PlayArea.console}) {
  if (error is StoreException) return error;
  if (error is DetailedApiRequestError) {
    return playStatusFailure(error.status, area: area);
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

/// What an HTTP status from any of the three Google APIs means to the user.
StoreException playStatusFailure(
  int? status, {
  PlayArea area = PlayArea.console,
}) {
  final bucket = area == PlayArea.bucket;
  return switch (status) {
    401 => _refused,
    403 => StoreException(
      StoreFailure.permission,
      bucket
          ? 'The service account may not read the reports bucket. In Play '
                'Console → Users and permissions, give it access to the '
                "app's reports (View app information and download bulk "
                'reports).'
          : 'The service account may not see this. Invite it in Play '
                'Console → Users and permissions with access to the app.',
    ),
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

/// Runs [call] so that whatever it throws leaves as a [StoreException].
Future<T> playGuarded<T>(
  Future<T> Function() call, {
  PlayArea area = PlayArea.console,
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
