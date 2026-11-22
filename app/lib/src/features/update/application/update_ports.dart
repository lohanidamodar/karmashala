import '../domain/install_kind.dart';

/// One HTTP answer, read whole.
final class UpdateHttpResponse {
  const UpdateHttpResponse(
    this.statusCode,
    this.body, {
    this.headers = const {},
  });

  final int statusCode;
  final String body;

  /// Lower-case names.
  final Map<String, String> headers;
}

/// A download in flight: its status, its length when known and its bytes.
final class UpdateHttpStream {
  const UpdateHttpStream(this.statusCode, this.contentLength, this.bytes);

  final int statusCode;

  /// -1 when the server did not say.
  final int contentLength;
  final Stream<List<int>> bytes;
}

/// The network, for the release check and the download. Faked in tests: no
/// test makes a request.
abstract interface class UpdateHttp {
  Future<UpdateHttpResponse> get(Uri url, {Map<String, String> headers});

  /// Follows redirects (GitHub's asset links redirect to its storage).
  Future<UpdateHttpStream> download(Uri url);
}

/// Where a download is written.
abstract interface class UpdateFileSink {
  void add(List<int> bytes);
  Future<void> close();
}

/// The files and processes an update touches, behind one seam so tests can
/// fake every one of them.
abstract interface class UpdateSystem {
  /// What the process can see about how it was installed.
  Future<InstallFacts> installFacts();

  /// A folder for downloads that nothing else uses.
  Future<String> downloadDirectory();

  String join(String directory, String name);

  Future<UpdateFileSink> create(String path);
  Future<void> delete(String path);

  /// Replaces [to] when it exists.
  Future<void> rename(String from, String to);
  Future<void> makeExecutable(String path);

  /// Starts [executable] so it outlives this process.
  Future<void> startDetached(String executable, List<String> arguments);

  /// Opens [path] the way the desktop would (a DMG mounts).
  Future<void> open(String path);

  /// Starts [executable] once this process has gone.
  Future<void> relaunchAfterExit(String executable);
}
