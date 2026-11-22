import 'dart:convert';

import 'package:cryptography/dart.dart' show DartSha256;
import 'package:karmashala/src/features/update/application/update_ports.dart';
import 'package:karmashala/src/features/update/domain/install_kind.dart';

/// Canned answers for the release check and the download. No socket.
class FakeUpdateHttp implements UpdateHttp {
  /// Answered in order; the last one repeats.
  final List<UpdateHttpResponse> answers = [];

  /// Thrown by [get] instead of answering.
  Object? throwOnGet;

  /// Every check made, with its headers.
  final List<Map<String, String>> checks = [];

  /// A download's bytes, by URL.
  final Map<Uri, List<int>> files = {};
  int downloadStatus = 200;
  final List<Uri> downloads = [];

  void answerJson(Object json, {int status = 200, String? etag}) => answers.add(
    UpdateHttpResponse(status, jsonEncode(json), headers: {'etag': ?etag}),
  );

  @override
  Future<UpdateHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    checks.add(headers);
    final failure = throwOnGet;
    if (failure != null) throw failure;
    return answers.length > 1 ? answers.removeAt(0) : answers.single;
  }

  @override
  Future<UpdateHttpStream> download(Uri url) async {
    downloads.add(url);
    final bytes = files[url] ?? const <int>[];
    return UpdateHttpStream(
      downloadStatus,
      bytes.length,
      Stream.fromIterable([
        for (var i = 0; i < bytes.length; i += 1000)
          bytes.sublist(i, i + 1000 > bytes.length ? bytes.length : i + 1000),
      ]),
    );
  }
}

/// Records every file and process action instead of doing it.
class FakeUpdateSystem implements UpdateSystem {
  FakeUpdateSystem(this.facts);

  InstallFacts facts;
  final Map<String, List<int>> written = {};
  final List<String> deleted = [];
  final List<(String, String)> renamed = [];
  final List<String> madeExecutable = [];
  final List<(String, List<String>)> started = [];
  final List<String> opened = [];
  final List<String> relaunched = [];

  @override
  Future<InstallFacts> installFacts() async => facts;

  @override
  Future<String> downloadDirectory() async => '/tmp/karmashala-update';

  @override
  String join(String directory, String name) => '$directory/$name';

  @override
  Future<UpdateFileSink> create(String path) async =>
      _RecordingSink(written[path] = []);

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
    written.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    renamed.add((from, to));
    final bytes = written.remove(from);
    if (bytes != null) written[to] = bytes;
  }

  @override
  Future<void> makeExecutable(String path) async => madeExecutable.add(path);

  @override
  Future<void> startDetached(String executable, List<String> arguments) async =>
      started.add((executable, arguments));

  @override
  Future<void> open(String path) async => opened.add(path);

  @override
  Future<void> relaunchAfterExit(String executable) async =>
      relaunched.add(executable);
}

class _RecordingSink implements UpdateFileSink {
  _RecordingSink(this._bytes);

  final List<int> _bytes;

  @override
  void add(List<int> bytes) => _bytes.addAll(bytes);

  @override
  Future<void> close() async {}
}

/// `sha256:<hex>` of [bytes], as GitHub writes an asset's digest.
Future<String> digestOf(List<int> bytes) async {
  final hash = await const DartSha256().hash(bytes);
  return 'sha256:${[for (final b in hash.bytes) b.toRadixString(16).padLeft(2, '0')].join()}';
}

/// A release as GitHub's API answers it.
Map<String, Object?> releaseJson({
  String tag = 'v1.35.0',
  String body = '## Fixed\n- Things',
  List<Map<String, Object?>> assets = const [],
  bool draft = false,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'name': 'Karmashala ${tag.substring(1)}',
  'html_url': 'https://github.com/lohanidamodar/karmashala/releases/tag/$tag',
  'body': body,
  'draft': draft,
  'prerelease': prerelease,
  'assets': assets,
};

Map<String, Object?> assetJson(String name, int size, {String? digest}) => {
  'name': name,
  'size': size,
  'browser_download_url':
      'https://github.com/lohanidamodar/karmashala/releases/download/v1.35.0/$name',
  'digest': ?digest,
};
