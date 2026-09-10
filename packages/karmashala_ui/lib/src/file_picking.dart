/// Every "Browse…" goes through here, for two reasons the log alone cannot
/// give: the picker is recorded *before* it is asked for, and it is always
/// handed a live **local** starting directory. Given none, the shell restores
/// this executable's `LastVisitedPidlMRU` folder, and when that is a
/// `\\wsl.localhost` path the dialog cannot draw it without enumerating
/// Network — **30.3 s, measured 2026-09-10** (two cold runs, 30,683 and
/// 30,335 ms; the same folder over the file redirector answers in 4 ms).
/// Occupying the isolate reproduces the same frozen window, which is what the
/// 2026-09-04 measurement did and why the diagnosis went the wrong way; the
/// quieting below is kept because a dialog does need the thread, but it was
/// never the reported cause. See docs/SETTLED.md.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'package:karmashala_core/logging.dart';

/// The picker types a caller needs, so nothing outside this file imports
/// `file_selector` and goes round the announcement.
export 'package:file_selector/file_selector.dart' show XFile, XTypeGroup;

/// The host's open-file dialog. A seam, so a test can stand where the platform
/// thread would be.
@visibleForTesting
typedef ShowFileDialog =
    Future<XFile?> Function({
      List<XTypeGroup> acceptedTypeGroups,
      String? confirmButtonText,
      String? initialDirectory,
    });

/// The host's choose-directory dialog. A seam, as above.
@visibleForTesting
typedef ShowDirectoryDialog =
    Future<String?> Function({
      String? confirmButtonText,
      String? initialDirectory,
    });

/// Whether a directory is there. A seam; only ever asked about a path that has
/// already been found local, because the stat itself is what can block.
@visibleForTesting
typedef DirectoryProbe = bool Function(String path);

final _logger = AppLogger.named('picker');

/// Told `true` when a picker is about to be shown and `false` when it has
/// answered. Never called with the value it was last given.
typedef PickerQuietHook = void Function(bool quiet);

/// Everything on this isolate that must stop while a host dialog is being
/// created. **Pause, never tear down** — a reconnect is worse than a freeze.
class PickerQuiet {
  /// The one every [pickOneFile] and [pickOneDirectory] announces to.
  static final PickerQuiet instance = PickerQuiet();

  final List<PickerQuietHook> _hooks = [];
  int _depth = 0;

  /// Whether a picker is up right now.
  bool get isQuiet => _depth > 0;

  /// How many subsystems are registered. For a test that has to prove one let
  /// go of its registration.
  @visibleForTesting
  int get registered => _hooks.length;

  /// Registers [hook] and returns the callback that removes it. A hook added
  /// while a picker is up is quieted at once; one removed is released.
  VoidCallback register(PickerQuietHook hook) {
    _hooks.add(hook);
    if (isQuiet) _tell(hook, true);
    return () {
      if (_hooks.remove(hook) && isQuiet) _tell(hook, false);
    };
  }

  /// Quiets every registrant. The returned callback resumes them, and is safe
  /// to call more than once.
  VoidCallback begin() {
    if (_depth++ == 0) {
      for (final hook in [..._hooks]) {
        _tell(hook, true);
      }
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_depth == 0) {
        for (final hook in [..._hooks]) {
          _tell(hook, false);
        }
      }
    };
  }

  // One registrant's failure is not the picker's problem, and above all is not
  // a reason to leave the others quiet.
  void _tell(PickerQuietHook hook, bool quiet) {
    try {
      hook(quiet);
    } on Object catch (error, stack) {
      _logger.warning('a picker-quiet hook refused $quiet', error, stack);
    }
  }
}

String? _lastPicked;

/// The directory a picker last chose here — the middle leg of
/// [pickerStartDirectory]'s chain. This run only; nothing is persisted.
@visibleForTesting
String? get lastPickedDirectory => _lastPicked;

@visibleForTesting
void forgetLastPickedDirectory() => _lastPicked = null;

/// Where a picker opens. [near] is the caller's own best idea — a project
/// folder, or whatever is already in the field beside the button; a file's
/// parent counts. Falls back to the last directory chosen here, then the
/// user's profile, and never answers null, a UNC path, or a dead one.
String pickerStartDirectory(
  String? near, {
  DirectoryProbe probe = _directoryIsThere,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final parent = near == null ? null : _parentOf(near);
  for (final candidate in [
    near,
    parent,
    _lastPicked,
    env['USERPROFILE'],
    env['HOME'],
  ]) {
    final usable = _localLiveDirectory(candidate, probe);
    if (usable != null) return usable;
  }
  return _floor(env);
}

/// [path] trimmed, or null when it is not somewhere this dialog may start.
/// A UNC or WSL spelling is refused *before* the probe: reaching one is the
/// cost this whole file exists to avoid, and a stat reaches it too.
String? _localLiveDirectory(String? path, DirectoryProbe probe) {
  // A trailing separator names the same folder; a probe need not agree.
  var candidate = path?.trim();
  if (candidate != null && candidate.length > 3) {
    candidate = candidate.replaceAll(RegExp(r'[\\/]+$'), '');
  }
  if (candidate == null || candidate.isEmpty) return null;
  if (candidate.startsWith(r'\\') || candidate.startsWith('//')) return null;
  final lower = candidate.toLowerCase();
  if (lower.contains(r'wsl$') || lower.contains('wsl.localhost')) return null;
  try {
    return probe(candidate) ? candidate : null;
  } on Object {
    return null;
  }
}

/// Answers false rather than throwing: a junction chain raises here (§20), and
/// an unreachable directory is no more startable than an absent one.
bool _directoryIsThere(String path) {
  try {
    return Directory(path).existsSync();
  } on Object {
    return false;
  }
}

String? _parentOf(String path) {
  final trimmed = path.trim().replaceAll(RegExp(r'[\\/]+$'), '');
  final cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  if (cut <= 0) return null;
  final parent = trimmed.substring(0, cut);
  return parent.endsWith(':') ? '$parent\\' : parent;
}

/// The last resort, unprobed: something certainly-local beats null, which is
/// what hands the folder back to the MRU.
String _floor(Map<String, String> env) {
  final drive = env['SystemDrive'];
  if (drive != null && drive.isNotEmpty) {
    return drive.endsWith(r'\') ? drive : '$drive\\';
  }
  return Platform.pathSeparator == r'\' ? r'C:\' : '/';
}

/// Remembers where a choice was made, so the next picker with no idea of its
/// own opens there instead of wherever the shell last was.
void _remember(String? directory) {
  final usable = _localLiveDirectory(directory, _directoryIsThere);
  if (usable != null) _lastPicked = usable;
}

/// Asks the host for one file, announcing it first. [what] is the thing being
/// chosen, in the user's words — the only clue to which Browse was pressed.
/// [startNear] is where to open; see [pickerStartDirectory] for what happens
/// when it is null or is not somewhere we may start.
Future<XFile?> pickOneFile({
  required String what,
  String? startNear,
  List<XTypeGroup> acceptedTypeGroups = const [],
  @visibleForTesting ShowFileDialog show = openFile,
  @visibleForTesting Diagnostics? diagnostics,
  @visibleForTesting PickerQuiet? quiet,
  @visibleForTesting DirectoryProbe probe = _directoryIsThere,
  @visibleForTesting Map<String, String>? environment,
}) async {
  final start = pickerStartDirectory(
    startNear,
    probe: probe,
    environment: environment,
  );
  // Before the announce, not between it and the call: the flush below yields,
  // and whatever runs in that gap is already on the thread the dialog needs.
  final resume = (quiet ?? PickerQuiet.instance).begin();
  await _announce('file', what, start, diagnostics);
  final elapsed = Stopwatch()..start();
  try {
    final file = await show(
      acceptedTypeGroups: acceptedTypeGroups,
      initialDirectory: start,
    );
    _remember(file == null ? null : _parentOf(file.path));
    _report('file', what, file?.path, elapsed);
    return file;
  } on Object catch (error, stack) {
    _fail('file', what, elapsed, error, stack);
    return null;
  } finally {
    resume();
  }
}

/// Asks the host for one directory, announcing it first.
Future<String?> pickOneDirectory({
  required String what,
  String? startNear,
  String? confirmButtonText,
  @visibleForTesting ShowDirectoryDialog show = getDirectoryPath,
  @visibleForTesting Diagnostics? diagnostics,
  @visibleForTesting PickerQuiet? quiet,
  @visibleForTesting DirectoryProbe probe = _directoryIsThere,
  @visibleForTesting Map<String, String>? environment,
}) async {
  final start = pickerStartDirectory(
    startNear,
    probe: probe,
    environment: environment,
  );
  final resume = (quiet ?? PickerQuiet.instance).begin();
  await _announce('directory', what, start, diagnostics);
  final elapsed = Stopwatch()..start();
  try {
    final directory = await show(
      confirmButtonText: confirmButtonText,
      initialDirectory: start,
    );
    _remember(directory);
    _report('directory', what, directory, elapsed);
    return directory;
  } on Object catch (error, stack) {
    _fail('directory', what, elapsed, error, stack);
    return null;
  } finally {
    resume();
  }
}

/// Logs that the picker is about to be shown, and gets that line onto disk
/// before it is. Awaited, not fired off — that is the whole point. [start] is
/// on the line because a freeze names its own suspect that way.
Future<void> _announce(
  String kind,
  String what,
  String start,
  Diagnostics? diagnostics,
) async {
  _logger.info('opening the $kind picker for $what, starting at $start');
  try {
    await (diagnostics ?? Diagnostics.instance).flushFile();
  } on Object {
    // A log file that will not write is not a reason to withhold the picker.
  }
}

void _report(String kind, String what, String? chosen, Stopwatch elapsed) {
  final ms = elapsed.elapsedMilliseconds;
  _logger.info(
    chosen == null
        ? 'the $kind picker for $what was dismissed after $ms ms'
        : 'the $kind picker for $what chose $chosen after $ms ms',
  );
}

/// Returns null rather than rethrowing: seven of the app's eight picker calls
/// had no catch, so a refusal took the enclosing callback with it.
void _fail(
  String kind,
  String what,
  Stopwatch elapsed,
  Object error,
  StackTrace stack,
) {
  _logger.warning(
    'the $kind picker for $what failed after ${elapsed.elapsedMilliseconds} ms',
    error,
    stack,
  );
}
