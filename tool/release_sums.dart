// Writes SHA256SUMS.txt for every file on a release, in `sha256sum` format.
// Scoop's autoupdate reads it, and so can anyone verifying a download by hand.
//
//   gh api repos/<owner>/<name>/releases/tags/<tag> > release.json
//   dart tool/release_sums.dart --release release.json --out build/sums
//
// Built from GitHub's own record of the release: each asset carries the
// SHA-256 GitHub computed when it was uploaded (`digest`), so nothing is
// downloaded again. The desktop app reads the same digests from the GitHub
// API itself (app/lib/src/features/update/). Plain dart:io, so it needs no
// `pub get`. See packaging/README.md.
import 'dart:convert';
import 'dart:io';

void main(List<String> argv) {
  final args = _parse(argv);
  final releasePath = args['release'];
  if (releasePath == null) {
    stderr.writeln(
      'usage: dart tool/release_sums.dart --release <release.json> '
      '[--out <dir>]',
    );
    exitCode = 64;
    return;
  }
  final release =
      jsonDecode(File(releasePath).readAsStringSync()) as Map<String, Object?>;
  final sums = ReleaseSums.fromGitHub(release);
  final out = Directory(args['out'] ?? '.')..createSync(recursive: true);
  File('${out.path}/SHA256SUMS.txt').writeAsStringSync(sums.text);
  for (final warning in sums.warnings) {
    // Warnings, not failures: one platform's build failing must not stop
    // the package managers hearing of the release.
    stdout.writeln('::warning::$warning');
  }
  stdout.writeln(
    'Wrote ${out.path}/SHA256SUMS.txt (${sums.version}, '
    '${sums.count} files).',
  );
}

/// The files each desktop install updates from, by the release workflow's
/// names (and the app's `assetNameFor`). Missing ones are warned about.
List<String> desktopAssetNames(String version) => [
  'Karmashala-Setup-$version.exe',
  'Karmashala-windows-portable.zip',
  'Karmashala-macOS-$version.dmg',
  'Karmashala-$version-x86_64.AppImage',
];

class ReleaseSums {
  ReleaseSums._(this.version, this.text, this.count, this.warnings);

  final String version;
  final String text;
  final int count;
  final List<String> warnings;

  /// From `GET /repos/{owner}/{repo}/releases/tags/{tag}`.
  factory ReleaseSums.fromGitHub(Map<String, Object?> release) {
    final tag = release['tag_name'] as String;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    final warnings = <String>[];
    final lines = <String>[];
    final names = <String>{};
    final files = [
      for (final asset in (release['assets'] as List<Object?>? ?? const []))
        asset as Map<String, Object?>,
    ]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    for (final file in files) {
      final name = file['name'] as String;
      // Our own output, from an earlier run of this job.
      if (name == 'SHA256SUMS.txt') continue;
      final digest = '${file['digest'] ?? ''}';
      if (!RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)) {
        warnings.add('$name has no SHA-256 digest on GitHub; left out.');
        continue;
      }
      lines.add('${digest.substring(7).toLowerCase()}  $name');
      names.add(name);
    }
    for (final name in desktopAssetNames(version)) {
      if (!names.contains(name)) {
        warnings.add('The release has no verified $name.');
      }
    }
    return ReleaseSums._(
      version,
      lines.isEmpty ? '' : '${lines.join('\n')}\n',
      lines.length,
      warnings,
    );
  }
}

Map<String, String> _parse(List<String> argv) {
  final args = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (!arg.startsWith('--')) continue;
    final eq = arg.indexOf('=');
    if (eq > 0) {
      args[arg.substring(2, eq)] = arg.substring(eq + 1);
    } else if (i + 1 < argv.length) {
      args[arg.substring(2)] = argv[++i];
    }
  }
  return args;
}
