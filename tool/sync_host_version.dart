// Writes the app's release (app/pubspec.yaml's version, without its build
// number) into kHostVersion, which `dart build cli` cannot take as a define.
// Every release build runs it first, so bumping the app alone still ships a
// host that reports the same version; server/test/protocol/host_version_test.dart
// stays as the guard on commits.
//
//   dart tool/sync_host_version.dart            # rewrite if stale
//   dart tool/sync_host_version.dart --check    # exit 1 if stale, write nothing
//
// Run from the repository root. Plain `dart:io`, so it needs no `pub get`.
import 'dart:io';

const _pubspec = 'app/pubspec.yaml';
const _hostVersion =
    'packages/karmashala_host_protocol/lib/src/protocol/host_version.dart';

final _versionLine = RegExp(r'^version:\s*([^\s+]+)', multiLine: true);
final _constant = RegExp(r"const String kHostVersion = '[^']*';");

/// The release in a pubspec: `version: 1.32.0+61` gives `1.32.0`.
String releaseOf(String pubspec) {
  final match = _versionLine.firstMatch(pubspec);
  if (match == null) throw const FormatException('no version: line');
  return match.group(1)!;
}

/// [source] with kHostVersion set to [release]; unchanged when it already is.
String withHostVersion(String source, String release) {
  if (!_constant.hasMatch(source)) {
    throw const FormatException('no kHostVersion constant');
  }
  return source.replaceFirst(
    _constant,
    "const String kHostVersion = '$release';",
  );
}

void main(List<String> args) {
  final check = args.contains('--check');
  final release = releaseOf(File(_pubspec).readAsStringSync());
  final file = File(_hostVersion);
  final source = file.readAsStringSync();
  final synced = withHostVersion(source, release);
  if (synced == source) {
    stdout.writeln('kHostVersion is $release');
    return;
  }
  if (check) {
    stderr.writeln('kHostVersion is stale: app/pubspec.yaml says $release');
    exitCode = 1;
    return;
  }
  file.writeAsStringSync(synced);
  stdout.writeln('kHostVersion set to $release');
}
