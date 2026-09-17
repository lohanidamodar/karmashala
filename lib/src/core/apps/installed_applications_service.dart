import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import 'installed_application.dart';

/// Reads the desktop's own list of applications. One pass, on demand — nothing
/// polls (§19), and the answer is cached by the provider for the session.
///
/// **Measured on the owner's machine 2026-09-14: 180 applications in 1.3s**,
/// almost all of it the single PowerShell process that resolves the shortcuts.
class InstalledApplicationsService {
  InstalledApplicationsService(this._runner, {bool? windows, bool? macOs})
    : _windows = windows ?? Platform.isWindows,
      _macOs = macOs ?? Platform.isMacOS;

  final CommandRunner _runner;

  /// Injected so a test can ask for a host it is not running on — which list is
  /// read turns entirely on these two.
  final bool _windows;
  final bool _macOs;

  /// How long the Start Menu pass may take before it is given up on. Generous:
  /// it is one process, and a cold COM object on a busy machine is slow.
  static const Duration timeout = Duration(seconds: 30);

  /// Resolves every Start Menu shortcut to its target in one process. A `.lnk`
  /// is an OLE structured-storage file, so the shell is what reads it.
  static const String startMenuScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$roots = @(
  (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
  (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
) | Where-Object { Test-Path $_ }
if (-not $roots) { exit 0 }
$shell = New-Object -ComObject WScript.Shell
Get-ChildItem -LiteralPath $roots -Filter *.lnk -Recurse | ForEach-Object {
  $target = $shell.CreateShortcut($_.FullName).TargetPath
  if ($target -and $target.ToLower().EndsWith('.exe')) {
    "$($_.BaseName)`t$target"
  }
}
''';

  /// Where macOS keeps applications. `/System/Applications` is the built-in
  /// set, which on Ventura and later is not under `/Applications` at all.
  static const List<String> macApplicationRoots = [
    '/Applications',
    '/System/Applications',
    '/System/Applications/Utilities',
    '/Applications/Utilities',
  ];

  /// Where a Linux desktop looks for its menu, flatpak's exports included.
  static List<String> linuxApplicationRoots(String? home) => [
    '/usr/share/applications',
    '/usr/local/share/applications',
    '/var/lib/flatpak/exports/share/applications',
    '/var/lib/snapd/desktop/applications',
    if (home != null) ...[
      p.join(home, '.local/share/applications'),
      p.join(home, '.local/share/flatpak/exports/share/applications'),
    ],
  ];

  /// Everything this desktop lists, by name. **Never throws**: a list nobody
  /// could read comes back empty, and the dialog says so rather than looking
  /// like a machine with no applications on it.
  Future<List<InstalledApplication>> all() async {
    try {
      if (_windows) return await _windowsApplications();
      if (_macOs) return _macApplications();
      return _linuxApplications();
    } on Object {
      return const [];
    }
  }

  Future<List<InstalledApplication>> _windowsApplications() async {
    final result = await _runner.run(
      CommandRequest(
        executable: 'powershell.exe',
        // A readable `-Command`: no `-EncodedCommand` and no execution-policy
        // override, both of which behavioural antivirus scores as a dropper
        // (docs/windows-antivirus.md). Neither was needed — the policy governs
        // script *files*, not `-Command` — and `Process.start` quotes this one
        // argument for Windows itself, in UTF-16.
        arguments: ['-NoProfile', '-Command', startMenuScript],
        timeout: timeout,
      ),
    );
    return windowsApplicationsIn(result.stdout);
  }

  List<InstalledApplication> _macApplications() {
    final byKey = <String, InstalledApplication>{};
    final home = Platform.environment['HOME'];
    final roots = [
      ...macApplicationRoots,
      if (home != null) p.join(home, 'Applications'),
    ];
    for (final root in roots) {
      final directory = Directory(root);
      if (!directory.existsSync()) continue;
      for (final entry in directory.listSync(followLinks: false)) {
        if (p.extension(entry.path).toLowerCase() != '.app') continue;
        final app = InstalledApplication(
          name: p.basenameWithoutExtension(entry.path),
          launchPath: entry.path,
          source: root,
        );
        byKey.putIfAbsent(app.key, () => app);
      }
    }
    return byKey.values.toList()..sort(byApplicationName);
  }

  List<InstalledApplication> _linuxApplications() {
    final byKey = <String, InstalledApplication>{};
    for (final root in linuxApplicationRoots(Platform.environment['HOME'])) {
      final directory = Directory(root);
      if (!directory.existsSync()) continue;
      for (final entry in directory.listSync(followLinks: false)) {
        if (entry is! File || p.extension(entry.path) != '.desktop') continue;
        final String contents;
        try {
          contents = entry.readAsStringSync();
        } on Object {
          continue;
        }
        final app = desktopEntryIn(contents, source: root);
        if (app == null) continue;
        byKey.putIfAbsent(app.key, () => app);
      }
    }
    return byKey.values.toList()..sort(byApplicationName);
  }
}
