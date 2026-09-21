import 'dart:io';
import 'dart:typed_data';

import 'package:launch_at_startup/src/app_auto_launcher.dart';
import 'package:win32_registry/win32_registry.dart';

bool isRunningInMsix(String packageName) {
  final String resolvedExecutable = Platform.resolvedExecutable;
  final bool isMsix =
      resolvedExecutable.contains('WindowsApps') &&
      resolvedExecutable.contains(packageName);
  return isMsix;
}

class AppAutoLauncherImplWindows extends AppAutoLauncher {
  AppAutoLauncherImplWindows({
    required super.appName,
    required String appPath,
    List<String> args = const [],
    this.runKeyPath = defaultRunKeyPath,
    this.startupApprovedKeyPath = defaultStartupApprovedKeyPath,
  }) : super(appPath: appPath, args: args) {
    _registryValue = args.isEmpty ? appPath : '$appPath ${args.join(' ')}';
  }

  static const String defaultRunKeyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const String defaultStartupApprovedKeyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

  /// Fork-only: a test drives the whole sequence against a scratch key rather
  /// than the machine's real autostart entries.
  final String runKeyPath;
  final String startupApprovedKeyPath;

  late String _registryValue;

  static const int _startupApprovedRegKeyBytesLength = 12;

  /// Upstream opened every key with `KEY_ALL_ACCESS`, which also asks for
  /// WRITE_DAC and WRITE_OWNER, and never closed the handle it opened.
  T _withKey<T>(
    String path,
    RegistryAccess access,
    T Function(RegistryKey key) body,
  ) {
    final key = CURRENT_USER.open(
      path,
      config: RegistryOpenConfig(access: access),
    );
    try {
      return body(key);
    } finally {
      key.close();
    }
  }

  @override
  Future<bool> isEnabled() async {
    final String? value = _withKey(
      runKeyPath,
      RegistryAccess.read,
      (key) => key.getString(appName),
    );
    return value == _registryValue && await _isStartupApproved();
  }

  @override
  Future<bool> enable() async {
    _withKey(
      runKeyPath,
      RegistryAccess.readWrite,
      (key) => key.setValue(appName, RegistryValue.string(_registryValue)),
    );

    final bytes = Uint8List(_startupApprovedRegKeyBytesLength);
    // "2" as a first byte in this register means that the autostart is enabled
    bytes[0] = 2;

    _withKey(
      startupApprovedKeyPath,
      RegistryAccess.readWrite,
      (key) => key.setValue(appName, RegistryValue.binary(bytes)),
    );

    return true;
  }

  @override
  Future<bool> disable() async {
    _removeValue(runKeyPath);
    _removeValue(startupApprovedKeyPath);
    return true;
  }

  // https://renenyffenegger.ch/notes/Windows/registry/tree/HKEY_CURRENT_USER/Software/Microsoft/Windows/CurrentVersion/Explorer/StartupApproved/Run/index
  // Odd first byte will prevent the app from autostarting
  // Empty or any other value will allow the app to autostart
  Future<bool> _isStartupApproved() async {
    final value = _withKey(
      startupApprovedKeyPath,
      RegistryAccess.read,
      (key) => key.getBinary(appName),
    );

    if (value == null) {
      return true;
    }

    if (value.isEmpty) {
      return true;
    }

    return value[0].isEven;
  }

  void _removeValue(String path) {
    _withKey(path, RegistryAccess.readWrite, (key) {
      if (key.getValue(appName) != null) {
        key.removeValue(appName);
      }
    });
  }
}

class AppAutoLauncherImplWindowsMsix extends AppAutoLauncher {
  AppAutoLauncherImplWindowsMsix({
    required super.appName,
    required super.appPath,
    required this.packageName,
    super.args,
  });

  final String packageName;

  File get _shortcutFile {
    return File(
      '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\$appName.lnk',
    );
  }

  @override
  Future<bool> isEnabled() async {
    return _shortcutFile.existsSync();
  }

  @override
  Future<bool> enable() async {
    final String script = '''
    \$TargetPath = "$appPath"
    \$ShortcutFile = "\$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\$appName.lnk"
    \$WScriptShell = New-Object -ComObject WScript.Shell
    \$Shortcut = \$WScriptShell.CreateShortcut(\$ShortcutFile)
    \$Shortcut.TargetPath = \$TargetPath
    \$Shortcut.Arguments = "${args.join(' ')}"
    \$Shortcut.Save()
  ''';
    final result = Process.runSync('powershell', ['-Command', script]);
    if (result.stderr != null && result.stderr!.isNotEmpty) {
      throw Exception('Failed to create shortcut: ${result.stderr}');
    }
    return _shortcutFile.existsSync();
  }

  @override
  Future<bool> disable() async {
    if (_shortcutFile.existsSync()) {
      final String script = '''
    Remove-Item -Path "\$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\$appName.lnk"
  ''';
      final result = Process.runSync('powershell', ['-Command', script]);
      if (result.stderr != null && result.stderr!.isNotEmpty) {
        throw Exception('Failed to delete shortcut: ${result.stderr}');
      }
    }
    return !_shortcutFile.existsSync();
  }
}
