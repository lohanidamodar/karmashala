/// The shell's per-executable "last visited folder", and why this app throws
/// its own away before every dialog.
///
/// Measured 2026-09-15 on a hung process: the main window was already
/// `enabled=False` — so `IFileDialog::Show` had been entered — **no `#32770`
/// window existed**, and the process held `MPR.dll`, `p9np.dll`, `ntlanman.dll`
/// and `davclnt.dll`. The dialog was enumerating Network while it built, before
/// it had a window. `SetFolder` does not prevent that: it chooses what is
/// *shown*, not what the dialog restores. See docs/SETTLED.md.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:karmashala_core/logging.dart';

/// Runs `reg.exe`. A seam, so a test never touches a real registry.
@visibleForTesting
typedef RegistryRunner = Future<ProcessResult> Function(List<String> arguments);

const _comDlg =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32';
const _mruKey = '$_comDlg\\LastVisitedPidlMRU';
const _recentKey = '$_comDlg\\OpenSavePidlMRU';

final _logger = AppLogger.named('picker');

/// Removes this executable's row from the shell's last-visited list, so the
/// next dialog has nothing to restore and opens where it is told.
///
/// Returns how many rows were removed. Never throws and never touches another
/// executable's row: the list is shared, and only ours is ours to drop.
///
/// Deliberately unconditional rather than "only when it looks remote". A row
/// only heals when a pick *succeeds*, and a dialog that never draws can never
/// be picked from — so a poisoned row would survive every attempt to use it.
/// Nothing is lost: [pickerStartDirectory] remembers this run's last folder,
/// and every caller passes a `startNear` of its own.
Future<int> forgetLastVisitedFolder({
  @visibleForTesting RegistryRunner? run,
  @visibleForTesting String? executableName,
}) async {
  // A suite must not rewrite the developer's own registry, and every test that
  // means to exercise this passes [run]. `FLUTTER_TEST` is set by the runner.
  if (run == null &&
      (!Platform.isWindows || Platform.environment['FLUTTER_TEST'] == 'true')) {
    return 0;
  }
  final runner = run ?? _reg;
  final ours = (executableName ?? _ownExecutableName()).toLowerCase();

  final List<String> values;
  try {
    values = await _valuesNaming(ours, runner);
  } on Object catch (error) {
    // A registry we could not read is not a reason to withhold the picker.
    _logger.debug('the last-visited list could not be read ($error)');
    return 0;
  }
  if (values.isEmpty) return 0;

  var removed = 0;
  for (final value in values) {
    try {
      final result = await runner(['delete', _mruKey, '/v', value, '/f']);
      if (result.exitCode == 0) removed++;
    } on Object catch (error) {
      _logger.debug('the last-visited row $value would not go ($error)');
    }
  }
  if (removed > 0) {
    _logger.info(
      'dropped $removed shell last-visited row(s) for $ours before the picker',
    );
  }
  return removed;
}

/// The value names under [_mruKey] whose blob begins with [ours]. The blob is
/// the executable's file name in UTF-16, NUL-terminated, then an ITEMIDLIST we
/// deliberately do not parse — what it points at does not change the answer.
Future<List<String>> _valuesNaming(String ours, RegistryRunner run) async {
  final result = await run(['query', _mruKey]);
  if (result.exitCode != 0) return const [];
  final names = <String>[];
  for (final line in const LineSplitter().convert('${result.stdout}')) {
    final match = RegExp(
      r'^\s+(\S+)\s+REG_BINARY\s+([0-9A-Fa-f]+)\s*$',
    ).firstMatch(line);
    if (match == null) continue;
    final name = match.group(1)!;
    if (name == 'MRUListEx') continue;
    if (_leadingName(match.group(2)!).toLowerCase() == ours) names.add(name);
  }
  return names;
}

/// The NUL-terminated UTF-16 string a value starts with, or `''` when the hex
/// is malformed or holds no terminator — neither of which may match anything.
String _leadingName(String hex) {
  final units = <int>[];
  for (var i = 0; i + 4 <= hex.length; i += 4) {
    final unit = int.tryParse(hex.substring(i + 2, i + 4), radix: 16);
    final low = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (unit == null || low == null) return '';
    final code = (unit << 8) | low;
    if (code == 0) return String.fromCharCodes(units);
    if (units.length > 260) return '';
    units.add(code);
  }
  return '';
}

String _ownExecutableName() {
  final path = Platform.resolvedExecutable.replaceAll('/', r'\');
  final cut = path.lastIndexOf(r'\');
  return cut == -1 ? path : path.substring(cut + 1);
}

Future<ProcessResult> _reg(List<String> arguments) =>
    Process.run('reg.exe', arguments, runInShell: false);

/// Drops the **remote** folders the shell would otherwise offer as "recent" for
/// the file types this picker is about to filter on.
///
/// Measured 2026-09-15, and it is the whole difference between two pickers in
/// this app: `OpenSavePidlMRU` is keyed on the *extension*, not the executable.
/// A picker filtering `*.exe` reads `…\exe`, which held no remote row and
/// opened in 828 ms; one filtering `*.apk` finds no `apk` key at all, falls
/// back to `…\*`, and binds the two `wsl$` rows there — loading `p9np.dll` and
/// `MPR.dll` and enumerating Network, which is the forty-second freeze.
///
/// Unlike [forgetLastVisitedFolder] this list is **shared with every other
/// application**, so only rows naming a WSL share or a UNC path are removed —
/// the ones that hang whichever app binds them — and never a local folder
/// somebody else put there. Returns how many were dropped.
Future<int> forgetRemoteRecentFolders({
  required List<String> extensions,
  @visibleForTesting RegistryRunner? run,
}) async {
  if (run == null &&
      (!Platform.isWindows || Platform.environment['FLUTTER_TEST'] == 'true')) {
    return 0;
  }
  final runner = run ?? _reg;
  // `*` always: it is what the dialog falls back to for a type with no key of
  // its own, which is exactly the case that broke.
  final keys = <String>{
    '*',
    for (final extension in extensions)
      extension.toLowerCase().replaceAll('.', '').trim(),
  }..removeWhere((key) => key.isEmpty);

  var removed = 0;
  for (final key in keys) {
    for (final value in await _remoteRowsUnder(key, runner)) {
      try {
        final result = await runner([
          'delete',
          '$_recentKey\\$key',
          '/v',
          value,
          '/f',
        ]);
        if (result.exitCode == 0) removed++;
      } on Object catch (error) {
        _logger.debug(
          'the recent-folder row $key/$value would not go ($error)',
        );
      }
    }
  }
  if (removed > 0) {
    _logger.info(
      'dropped $removed remote recent-folder row(s) from ${keys.join(", ")} '
      'before the picker',
    );
  }
  return removed;
}

/// The value names under `OpenSavePidlMRU\[key]` whose blob names a WSL share
/// or a UNC path. The ITEMIDLIST is not parsed: its display names are UTF-16 in
/// the blob, which is all that has to be recognised.
Future<List<String>> _remoteRowsUnder(String key, RegistryRunner run) async {
  final ProcessResult result;
  try {
    result = await run(['query', '$_recentKey\\$key']);
  } on Object {
    return const [];
  }
  if (result.exitCode != 0) return const [];
  final names = <String>[];
  for (final line in const LineSplitter().convert('${result.stdout}')) {
    final match = RegExp(
      r'^\s+(\S+)\s+REG_BINARY\s+([0-9A-Fa-f]+)\s*$',
    ).firstMatch(line);
    if (match == null) continue;
    if (match.group(1) == 'MRUListEx') continue;
    if (_namesSomethingRemote(match.group(2)!)) names.add(match.group(1)!);
  }
  return names;
}

bool _namesSomethingRemote(String hex) {
  final units = <int>[];
  for (var i = 0; i + 4 <= hex.length; i += 4) {
    final high = int.tryParse(hex.substring(i + 2, i + 4), radix: 16);
    final low = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (high == null || low == null) return false;
    units.add((high << 8) | low);
  }
  final text = String.fromCharCodes(
    units.where((unit) => unit >= 0x20 && unit < 0xFFFF),
  ).toLowerCase();
  return text.contains(r'wsl$') ||
      text.contains('wsl.localhost') ||
      text.contains(r'\\');
}
