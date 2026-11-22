import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path/path.dart' as p;

import '../../../core/lifecycle/relaunch.dart' as lifecycle;
import '../application/update_ports.dart';
import '../domain/install_kind.dart';

/// Android's install source (`MainActivity`'s `InstallSourceChannel`).
const _installSource = MethodChannel('karmashala/install_source');

/// [UpdateSystem] over `dart:io`.
class IoUpdateSystem implements UpdateSystem {
  @override
  Future<InstallFacts> installFacts() async {
    if (kIsWeb) return const InstallFacts(os: 'web');
    final os = Platform.operatingSystem;
    switch (os) {
      case 'windows':
        final folder = File(Platform.resolvedExecutable).parent;
        return InstallFacts(
          os: os,
          namesBesideExecutable: [
            for (final entity in folder.listSync(followLinks: false))
              if (entity is File) p.basename(entity.path),
          ],
        );
      case 'linux':
        return InstallFacts(os: os, appImage: Platform.environment['APPIMAGE']);
      case 'android':
        try {
          final installer = await _installSource.invokeMethod<String>(
            'installer',
          );
          return InstallFacts(
            os: os,
            androidInstallerKnown: true,
            androidInstaller: installer,
          );
        } on Object {
          return InstallFacts(os: os);
        }
      default:
        return InstallFacts(os: os);
    }
  }

  @override
  Future<String> downloadDirectory() async {
    final folder = Directory(
      p.join(Directory.systemTemp.path, 'karmashala-update'),
    );
    await folder.create(recursive: true);
    return folder.path;
  }

  @override
  String join(String directory, String name) => p.join(directory, name);

  @override
  Future<UpdateFileSink> create(String path) async =>
      _IoSink(File(path).openWrite());

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> rename(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  Future<void> makeExecutable(String path) async {
    final result = await Process.run('chmod', ['+x', path]);
    if (result.exitCode != 0) {
      throw StateError('chmod +x failed: ${result.stderr}');
    }
  }

  @override
  Future<void> startDetached(String executable, List<String> arguments) async {
    try {
      await Process.start(
        executable,
        arguments,
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (error) {
      // ERROR_ELEVATION_REQUIRED: CreateProcess will not raise a UAC prompt,
      // the shell will.
      if (!Platform.isWindows || error.errorCode != 740) rethrow;
      String quote(String value) => "'${value.replaceAll("'", "''")}'";
      await Process.start('powershell', [
        '-NoProfile',
        '-Command',
        'Start-Process -FilePath ${quote(executable)} '
            '-ArgumentList ${quote(arguments.join(' '))} -Verb RunAs',
      ], mode: ProcessStartMode.detached);
    }
  }

  @override
  Future<void> open(String path) async {
    final result = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('could not open $path: ${result.stderr}');
    }
  }

  @override
  Future<void> relaunchAfterExit(String executable) =>
      lifecycle.relaunchAfterExit(executable: executable);
}

class _IoSink implements UpdateFileSink {
  _IoSink(this._sink);

  final IOSink _sink;

  @override
  void add(List<int> bytes) => _sink.add(bytes);

  @override
  Future<void> close() => _sink.close();
}
