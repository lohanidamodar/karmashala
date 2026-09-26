import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// **One canned HTTP answer, with no socket anywhere near it.**
///
/// The usage endpoints are the vendors' own, and a test that dialled them would
/// spend the owner's quota to prove a parser — and, for the rate-limit tests,
/// would be asking the very endpoint that is refusing us. Everything the
/// service reads off a response is settable here: the status, the body and the
/// headers (`Retry-After` is the one that matters).
class FakeHttpClient implements HttpClient {
  FakeHttpClient({
    this.statusCode = 200,
    this.body = '{}',
    Map<String, String>? responseHeaders,
  }) : responseHeaders = responseHeaders ?? {};

  int statusCode;
  String body;

  /// Thrown instead of answering — what a socket failure looks like from here.
  Object? throwOnRequest;

  /// Header names are matched case-insensitively, as `HttpHeaders` does.
  Map<String, String> responseHeaders;

  /// Every URL asked for, in order. The count is the number that matters: a
  /// backoff is only real if the request is *not* made.
  final List<Uri> requestedUrls = [];

  /// The `Authorization` header of each request, so a test can prove which
  /// token was sent without ever printing one that is real.
  final List<String?> sentAuthorization = [];

  int get requests => requestedUrls.length;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requestedUrls.add(url);
    final failure = throwOnRequest;
    if (failure != null) throw failure;
    return _FakeRequest(
      _FakeResponse(statusCode, body, _FakeHeaders(responseHeaders)),
      sentAuthorization,
    );
  }

  /// The service closes its client in a `finally`, so this is on the path of
  /// every fetch including the failing ones.
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A response the service can read, without a socket.
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this.body, this.headers);

  @override
  final int statusCode;
  final String body;

  @override
  final HttpHeaders headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.response, this.sentAuthorization);

  final _FakeResponse response;
  final List<String?> sentAuthorization;

  @override
  final HttpHeaders headers = _FakeHeaders({});

  @override
  Future<HttpClientResponse> close() async {
    sentAuthorization.add((headers as _FakeHeaders).values['authorization']);
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders(Map<String, String> initial)
    : values = {
        for (final entry in initial.entries)
          entry.key.toLowerCase(): entry.value,
      };

  final Map<String, String> values;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
