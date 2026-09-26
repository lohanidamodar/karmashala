@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:launch_at_startup/windows.dart';
import 'package:win32_registry/win32_registry.dart';

/// The registry writes behind "start Karmashala at login", driven against a
/// scratch key under `HKCU\Software` rather than the machine's real autostart:
/// the byte protocol and the win32_registry 3 calls are what can break, and
/// neither needs the real key to be exercised.
void main() {
  const appName = 'Karmashala';
  const appPath = r'C:\Karmashala\karmashala.exe';

  late String root;
  late String runPath;
  late String approvedPath;

  setUp(() {
    root = r'Software\KarmashalaAutostartTest' '${pid}_${_counter++}';
    runPath = '$root\\Run';
    approvedPath = '$root\\StartupApproved';
    CURRENT_USER.create(runPath).close();
    CURRENT_USER.create(approvedPath).close();
  });

  tearDown(() {
    final software = CURRENT_USER.open(
      'Software',
      config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
    );
    try {
      software.removeSubkey(root.substring('Software\\'.length));
    } finally {
      software.close();
    }
  });

  AppAutoLauncherImplWindows launcher({List<String> args = const []}) =>
      AppAutoLauncherImplWindows(
        appName: appName,
        appPath: appPath,
        args: args,
        runKeyPath: runPath,
        startupApprovedKeyPath: approvedPath,
      );

  String? runValue() => _read(runPath, (key) => key.getString(appName));
  Uint8List? approvedValue() =>
      _read(approvedPath, (key) => key.getBinary(appName));

  test('an app that was never enabled reads as disabled', () async {
    expect(await launcher().isEnabled(), isFalse);
  });

  test('enable writes the executable path and marks it approved', () async {
    await launcher().enable();

    expect(runValue(), appPath);
    final approved = approvedValue();
    expect(approved, isNotNull);
    expect(approved!.first, 2, reason: 'an even first byte means enabled');
    expect(await launcher().isEnabled(), isTrue);
  });

  test('args are appended to the stored command', () async {
    await launcher(args: const ['--silent']).enable();

    expect(runValue(), '$appPath --silent');
    expect(await launcher(args: const ['--silent']).isEnabled(), isTrue);
    // The same executable under different args is a different command line.
    expect(await launcher().isEnabled(), isFalse);
  });

  test('an odd approval byte reads as disabled, as Task Manager writes it',
      () async {
    await launcher().enable();
    _write(approvedPath, (key) {
      final bytes = Uint8List(12)..[0] = 3;
      key.setValue(appName, RegistryValue.binary(bytes));
    });

    expect(runValue(), appPath, reason: 'the Run value is left alone');
    expect(await launcher().isEnabled(), isFalse);
  });

  test('disable removes both values', () async {
    await launcher().enable();
    await launcher().disable();

    expect(runValue(), isNull);
    expect(approvedValue(), isNull);
    expect(await launcher().isEnabled(), isFalse);
  });

  test('disable on an app that was never enabled does nothing', () async {
    await expectLater(launcher().disable(), completion(isTrue));
    expect(runValue(), isNull);
  });

  test('the defaults are the keys Windows reads at login', () {
    expect(
      AppAutoLauncherImplWindows.defaultRunKeyPath,
      r'Software\Microsoft\Windows\CurrentVersion\Run',
    );
    expect(
      AppAutoLauncherImplWindows.defaultStartupApprovedKeyPath,
      r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    );
  });
}

int _counter = 0;

T _read<T>(String path, T Function(RegistryKey key) body) {
  final key = CURRENT_USER.open(path);
  try {
    return body(key);
  } finally {
    key.close();
  }
}

void _write(String path, void Function(RegistryKey key) body) {
  final key = CURRENT_USER.open(
    path,
    config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
  );
  try {
    body(key);
  } finally {
    key.close();
  }
}
