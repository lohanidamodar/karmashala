/// Nothing in this library — and so no test calling it — can land in the
/// owner's real `~/.karmashala` by leaving something out. Found live
/// (2026-09-26): a test ran `serve` without `--data-dir` once that meant the
/// real home, and it opened the owner's store and wrote its MCP handshake
/// there. Now the environment is never defaulted inside the library: only
/// `bin/karmashala_host.dart` passes `Platform.environment`.
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/serve/attach_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'server_test_support.dart';

void main() {
  group('with nothing to resolve a home from, it is a programming error', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('kh-no-home'));
    tearDown(() => root.deleteSync(recursive: true));

    test('serve without --data-dir and without an environment', () async {
      await expectLater(
        runServe(
          const ['--companion-port=0'],
          out: CapturingSink(),
          err: CapturingSink(),
          paths: HostPaths(Directory(p.join(root.path, 'host'))),
        ),
        throwsArgumentError,
      );
      expect(Directory(p.join(root.path, 'host')).existsSync(), isFalse);
    });

    test('serve without a host directory and without an environment', () async {
      await expectLater(
        runServe(
          ['--data-dir=${p.join(root.path, 'data')}'],
          out: CapturingSink(),
          err: CapturingSink(),
        ),
        throwsArgumentError,
      );
      expect(Directory(p.join(root.path, 'data')).existsSync(), isFalse);
    });

    test('init without --data-dir and without an environment', () async {
      await expectLater(
        runInit(const ['--name=x'], out: CapturingSink(), err: CapturingSink()),
        throwsArgumentError,
      );
    });

    test('the socket commands without paths and without an environment', () {
      for (final call in <Future<int> Function()>[
        () => runPair(const [], err: CapturingSink()),
        () => runDevices(const [], err: CapturingSink()),
        () => runRevoke(const ['abc'], err: CapturingSink()),
        () => runAgents(const [], err: CapturingSink()),
        () => runList(err: CapturingSink()),
        () => runEnd(const ['s1'], err: CapturingSink()),
        () => runStop(const [], err: CapturingSink()),
        () => runAttach(const [], err: CapturingSink()),
      ]) {
        expect(call, throwsArgumentError);
      }
    });

    test('the default data directory and host paths name no home of their '
        'own', () {
      expect(
        defaultServerDataDirectory(environment: const {'HOME': '/h'}),
        // The given home, joined the way this machine joins.
        Platform.isWindows ? r'/h\.karmashala' : '/h/.karmashala',
      );
      expect(
        HostPaths.resolve(
          environment: const {'KARMASHALA_HOST_DIR': '/elsewhere'},
        ).directory.path,
        '/elsewhere',
      );
    });
  });

  test('every call in server/test names its data, its host directory or its '
      'environment outright', () {
    // The commands that would otherwise resolve a home, and what each needs
    // to be told instead of one.
    const dataCommands = {'runServe', 'runInit', 'runHostCli'};
    const socketCommands = {
      'runPair',
      'runDevices',
      'runRevoke',
      'runAgents',
      'runList',
      'runEnd',
      'runStop',
      'runAttach',
    };
    final self = p.join('test', 'server', 'no_real_home_test.dart');
    final offenders = <String>[];
    for (final entity in Directory('test').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (p.equals(entity.path, self)) continue;
      final text = entity.readAsStringSync();
      for (final name in {...dataCommands, ...socketCommands}) {
        for (final match in RegExp('\\b$name\\(').allMatches(text)) {
          final call = _callText(text, match.end);
          final line = '\n'.allMatches(text.substring(0, match.start)).length;
          final where = '${entity.path}:${line + 1} $name';
          final environment = call.contains('environment:');
          if (dataCommands.contains(name)) {
            final named = call.contains('--data-dir=') || name == 'runHostCli';
            if (!environment && !named) offenders.add('$where: no data dir');
            if (name == 'runServe' &&
                !environment &&
                !call.contains('paths:')) {
              offenders.add('$where: no host directory');
            }
            if (name == 'runHostCli' && !environment) {
              offenders.add('$where: no environment');
            }
          } else if (!environment && !call.contains('paths:')) {
            offenders.add('$where: no host directory');
          }
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}

/// The argument text of the call whose `(` ends at [start], up to its
/// matching `)`.
String _callText(String text, int start) {
  var depth = 1;
  for (var i = start; i < text.length; i++) {
    final c = text[i];
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return text.substring(start, i);
  }
  return text.substring(start);
}
