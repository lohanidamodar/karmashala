/// Every "Browse…" goes through here so the log records that a picker was
/// asked for, and records it *before* asking — see docs/SETTLED.md for why.
library;

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

/// Asks the host for one file, announcing it first. [what] is the thing being
/// chosen, in the user's words — the only clue to which Browse was pressed.
Future<XFile?> pickOneFile({
  required String what,
  List<XTypeGroup> acceptedTypeGroups = const [],
  String? initialDirectory,
  @visibleForTesting ShowFileDialog show = openFile,
  @visibleForTesting Diagnostics? diagnostics,
  @visibleForTesting PickerQuiet? quiet,
}) async {
  // Before the announce, not between it and the call: the flush below yields,
  // and whatever runs in that gap is already on the thread the dialog needs.
  final resume = (quiet ?? PickerQuiet.instance).begin();
  await _announce('file', what, diagnostics);
  final elapsed = Stopwatch()..start();
  try {
    final file = await show(
      acceptedTypeGroups: acceptedTypeGroups,
      initialDirectory: initialDirectory,
    );
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
  String? confirmButtonText,
  String? initialDirectory,
  @visibleForTesting ShowDirectoryDialog show = getDirectoryPath,
  @visibleForTesting Diagnostics? diagnostics,
  @visibleForTesting PickerQuiet? quiet,
}) async {
  final resume = (quiet ?? PickerQuiet.instance).begin();
  await _announce('directory', what, diagnostics);
  final elapsed = Stopwatch()..start();
  try {
    final directory = await show(
      confirmButtonText: confirmButtonText,
      initialDirectory: initialDirectory,
    );
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
/// before it is. Awaited, not fired off — that is the whole point.
Future<void> _announce(
  String kind,
  String what,
  Diagnostics? diagnostics,
) async {
  _logger.info('opening the $kind picker for $what');
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
