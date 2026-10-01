// Builds the Linux session host bundles inside WSL, from the commit this
// checkout is at, for tool/build_release.bat when the release has none.
//
// Run with the *Windows* Dart; every Linux step goes through `wsl.exe -e`, with
// WSL's own Flutter SDK named by path. A bare `flutter` in WSL resolves to the
// Windows install and corrupts it (PROJECT.md §17), and a Linux bundle built on
// Windows cannot open its store (§22).
//
//   dart tool\build_host_linux.dart --version 1.29.0 --out <folder>
//       [--arch x64,arm64] [--clone <wsl path>] [--flutter <wsl path>]
//
// Exits 0 when the x64 bundle was written; arm64 is best effort.
import 'dart:io';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final version = options['version'];
  // Absolute, so `wslpath` reads it as a Windows path.
  final out = switch (options['out']) {
    final folder? => Directory(folder).absolute.path,
    null => null,
  };
  if (version == null || out == null) {
    stderr.writeln(
      'usage: dart tool\\build_host_linux.dart --version <x.y.z> --out <folder> '
      '[--arch x64,arm64] [--clone <wsl path>] [--flutter <wsl path>]',
    );
    exit(64);
  }
  final arches = (options['arch'] ?? 'x64,arm64').split(',');
  try {
    exit(await _build(version, out, arches, options));
  } on _Failed catch (failure) {
    stdout.writeln('LINUX HOST BUILD FAILED: ${failure.message}');
    exit(1);
  }
}

Future<int> _build(
  String version,
  String out,
  List<String> arches,
  Map<String, String> options,
) async {
  final commit = (await _capture('git', ['rev-parse', 'HEAD'])).trim();
  final gitDir = (await _capture('git', [
    'rev-parse',
    '--path-format=absolute',
    '--git-common-dir',
  ])).trim();
  final dirty = (await _capture('git', [
    'status',
    '--porcelain',
    '--untracked-files=no',
  ])).trim();
  stdout.writeln('building linux host bundles $version from commit $commit');
  if (dirty.isNotEmpty) {
    stdout.writeln(
      'WARNING: this checkout has uncommitted changes; the linux bundles are '
      'built from $commit without them.',
    );
  }

  final home = (await _capture('wsl.exe', ['-e', 'printenv', 'HOME'])).trim();
  if (!home.startsWith('/')) throw _Failed('WSL gave no home directory');
  final clone = options['clone'] ?? '$home/karmashala-host-build';
  final sdk = options['flutter'] ?? '$home/flutter';
  final flutter = '$sdk/bin/flutter';
  final dart = '$sdk/bin/dart';
  if (await _wsl(['test', '-x', flutter]) != 0) {
    throw _Failed('no Linux Flutter SDK at $sdk in WSL');
  }
  final source = (await _capture('wsl.exe', [
    '-e',
    'wslpath',
    '-a',
    gitDir.replaceAll('/', r'\'),
  ])).trim();
  final outWsl = (await _capture('wsl.exe', ['-e', 'wslpath', '-a', out]))
      .trim();

  if (await _wsl(['test', '-d', '$clone/.git']) != 0) {
    await _step('create the WSL clone $clone', ['git', 'init', '-q', clone]);
  }
  // By commit, from the local repository: it may not be pushed yet.
  await _step('fetch $commit from $source', [
    'git',
    '-C',
    clone,
    'fetch',
    '--no-tags',
    '-q',
    source,
    commit,
  ]);
  await _step('check out $commit', [
    'git',
    '-C',
    clone,
    'checkout',
    '-q',
    '--force',
    '--detach',
    commit,
  ]);
  // A .dart_tool from another commit's resolution breaks `pub get`.
  await _step('clean .dart_tool and build', [
    'rm',
    '-rf',
    '$clone/.dart_tool',
    '$clone/build',
  ]);
  if (await _wsl([flutter, 'pub', 'get', '--enforce-lockfile'], cd: clone) !=
      0) {
    stdout.writeln('pub get --enforce-lockfile failed; resolving afresh');
    await _step('flutter pub get', [flutter, 'pub', 'get'], cd: clone);
  }

  final built = <String>[];
  for (final arch in arches) {
    final name = 'karmashala_host-$version-linux-$arch.tar.gz';
    try {
      await _step('dart build cli (linux-$arch)', [
        dart,
        'build',
        'cli',
        '-t',
        'server/bin/karmashala_host.dart',
        '--target-os=linux',
        '--target-arch=$arch',
        '-o',
        'build/host-linux-$arch',
      ], cd: clone);
      // Written under another name first: a half-written archive with the
      // real one would be deployed.
      await _step('tar $name', [
        'tar',
        '-czf',
        '$outWsl/$name.part',
        '-C',
        'build/host-linux-$arch/bundle',
        '.',
      ], cd: clone);
      await _step('move $name into place', [
        'mv',
        '-f',
        '$outWsl/$name.part',
        '$outWsl/$name',
      ]);
      built.add(name);
    } on _Failed catch (failure) {
      stdout.writeln('linux-$arch NOT BUILT: ${failure.message}');
      await _wsl(['rm', '-f', '$outWsl/$name.part']);
    }
  }
  stdout.writeln(
    built.isEmpty
        ? 'no linux host bundle was built'
        : 'built into $out: ${built.join(', ')}',
  );
  return built.any((name) => name.endsWith('-linux-x64.tar.gz')) ? 0 : 1;
}

Future<void> _step(String what, List<String> command, {String? cd}) async {
  stdout.writeln('--- $what');
  final code = await _wsl(command, cd: cd);
  if (code != 0) throw _Failed('$what exited $code');
}

/// Runs [command] in WSL without a shell, its output into this one's.
Future<int> _wsl(List<String> command, {String? cd}) async {
  final process = await Process.start('wsl.exe', [
    if (cd != null) ...['--cd', cd],
    '-e',
    ...command,
  ], mode: ProcessStartMode.inheritStdio);
  return process.exitCode;
}

Future<String> _capture(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw _Failed(
      '`$executable ${args.join(' ')}` exited ${result.exitCode}: '
      '${'${result.stderr}'.trim()}',
    );
  }
  return '${result.stdout}';
}

Map<String, String> _parse(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    if (!args[i].startsWith('--')) break;
    options[args[i].substring(2)] = args[i + 1];
  }
  return options;
}

class _Failed implements Exception {
  _Failed(this.message);
  final String message;
}
