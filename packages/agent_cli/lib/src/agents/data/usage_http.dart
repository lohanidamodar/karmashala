import 'dart:convert';
import 'dart:io';

import '../../util/clock.dart';
import '../domain/usage_failure.dart';
import 'usage_exception.dart';

/// The HTTP half of a usage reading, shared by every agent's endpoint so a
/// rate limit, a struggling server and an expired token read the same way
/// whoever's endpoint said them.
class UsageHttp {
  UsageHttp({required HttpClient Function() newClient, required this.clock})
    : _newClient = newClient;

  final HttpClient Function() _newClient;
  final Clock clock;

  Future<Map<String, dynamic>> getJson(
    Uri url,
    Map<String, String> headers,
  ) async {
    final client = _newClient();
    try {
      final request = await client.getUrl(url);
      headers.forEach(request.headers.set);
      final response = await request.close();
      final status = response.statusCode;
      // Read the header before the body. On a `429` the body is a vendor error
      // blob we do not parse, and `Retry-After` — the one thing RFC 9110 says
      // every 429 may carry — is the only part of that answer worth having.
      // Both endpoints are treated identically here: neither is documented, and
      // guessing at a vendor-specific header we cannot observe without making
      // the very request we are trying not to make would be inventing evidence.
      final retryAfter = status >= HttpStatus.tooManyRequests
          ? parseRetryAfter(
              response.headers.value(HttpHeaders.retryAfterHeader),
              clock.nowUtc(),
            )
          : null;
      final body = await response.transform(utf8.decoder).join();
      // Neither of these carries the wait itself: how long to hold off is the
      // throttle's decision, because only it knows how many refusals came
      // before this one.
      if (status == HttpStatus.tooManyRequests) {
        throw UsageException(
          'Rate limited by the usage service.',
          kind: UsageFailureKind.rateLimited,
          retryIn: retryAfter,
        );
      }
      if (status >= HttpStatus.internalServerError) {
        throw UsageException(
          'The usage service is having trouble (HTTP $status).',
          kind: UsageFailureKind.serverBusy,
          retryIn: retryAfter,
        );
      }
      if (status == HttpStatus.unauthorized) {
        throw UsageException(
          'Access token expired. Run the agent once to refresh, then retry.',
          kind: UsageFailureKind.auth,
        );
      }
      if (status != HttpStatus.ok) {
        throw UsageException(
          'Usage request failed (HTTP $status).',
          kind: UsageFailureKind.unusable,
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw UsageException(
          'Unexpected usage response shape.',
          kind: UsageFailureKind.unusable,
        );
      }
      return decoded;
    } on UsageException {
      rethrow;
    } on FormatException catch (e) {
      // An answer we could not read is not an endpoint we could not reach, and
      // telling the user to check their network over a malformed body sends
      // them somewhere there is nothing to find.
      throw UsageException(
        'The usage service sent something we could not read: ${e.message}',
        kind: UsageFailureKind.unusable,
      );
    } catch (e) {
      throw UsageException(
        'Could not reach the usage service: $e',
        kind: UsageFailureKind.unreachable,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> postJson(
    Uri url,
    Map<String, String> headers,
    Object body,
  ) async {
    final client = _newClient();
    try {
      final request = await client.postUrl(url);
      headers.forEach(request.headers.set);
      request.write(jsonEncode(body));
      final response = await request.close();
      final resBody = await response.transform(utf8.decoder).join();
      if (response.statusCode == 401) {
        throw UsageException(
          'Access token expired. Run the agent once to refresh, then retry.',
        );
      }
      if (response.statusCode != 200) {
        throw UsageException(
          'Usage request failed (HTTP ${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(resBody);
      if (decoded is! Map<String, dynamic>) {
        throw UsageException('Unexpected usage response shape.');
      }
      return decoded;
    } on UsageException {
      rethrow;
    } catch (e) {
      throw UsageException('Could not reach the usage service: $e');
    } finally {
      client.close(force: true);
    }
  }
}

/// `Retry-After`, in either form RFC 9110 allows: a delay in seconds, or an
/// HTTP-date to wait until.
///
/// Null when the header is absent or unreadable — the caller then falls back to
/// its own doubling, which is the case that has to work anyway, since neither
/// vendor promises the header.
Duration? parseRetryAfter(String? header, DateTime now) {
  final raw = header?.trim();
  if (raw == null || raw.isEmpty) return null;
  final seconds = int.tryParse(raw);
  if (seconds != null) {
    return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
  }
  try {
    final until = HttpDate.parse(raw);
    final wait = until.difference(now);
    return wait.isNegative ? Duration.zero : wait;
  } on Exception {
    return null;
  }
}
