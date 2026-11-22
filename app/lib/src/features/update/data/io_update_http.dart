import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../application/update_ports.dart';

/// [UpdateHttp] over `dart:io`'s [HttpClient], as the agent version check
/// uses, rather than a package for two requests. Nothing about the person or
/// their machines is sent: no cookie, no token.
class IoUpdateHttp implements UpdateHttp {
  IoUpdateHttp({this.timeout = const Duration(seconds: 15)});

  /// For the release check, and for each wait on a download's next bytes.
  final Duration timeout;

  @override
  Future<UpdateHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final answered = <String, String>{};
      response.headers.forEach((name, values) {
        answered[name.toLowerCase()] = values.join(',');
      });
      return UpdateHttpResponse(response.statusCode, body, headers: answered);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<UpdateHttpStream> download(Uri url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'Karmashala');
      final response = await request.close().timeout(timeout);
      // A stalled transfer ends as an error rather than a bar that never
      // moves.
      final bytes = response
          .timeout(timeout * 4)
          .transform<List<int>>(
            StreamTransformer.fromHandlers(
              handleError: (error, stack, sink) {
                client.close(force: true);
                sink.addError(error, stack);
              },
              handleDone: (sink) {
                client.close();
                sink.close();
              },
            ),
          );
      return UpdateHttpStream(
        response.statusCode,
        response.contentLength,
        bytes,
      );
    } on Object {
      client.close(force: true);
      rethrow;
    }
  }
}
