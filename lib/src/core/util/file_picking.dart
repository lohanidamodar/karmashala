/// Every "Browse…" in this app goes through here, so the log records that a
/// picker was asked for — and records it *before* asking.
///
/// **Why that matters.** On Windows `file_selector` shows `IFileOpenDialog`
/// **synchronously on the platform thread**, and in the Flutter Windows
/// embedder the platform thread is the thread the Dart isolate runs on. The
/// dialog's creation and its own message loop therefore only make progress
/// while this isolate is idle. Anything that occupies the isolate after the
/// call leaves the dialog *created and never shown*, and stops the app's window
/// answering messages — which is exactly what Windows calls "Not Responding".
///
/// **Measured 2026-09-04 on the owner's machine**, in a release build of this
/// app: occupying the isolate for 25 s starting 50 ms after `openFile()` left
/// the `#32770` "Open" window at `visible=0`, `IsHungAppWindow` true for it
/// *and* for the app's own window, and `SendMessageTimeout(WM_NULL,
/// SMTO_ABORTIFHUNG)` unanswered on both; releasing the isolate showed the
/// dialog in the same instant. That reproduces the report — *"browse, nothing
/// load just that window turned not-responding after that"* — and it is not a
/// fault in the picker, nor in nesting it inside a Flutter dialog: the same
/// call answered in under two seconds from a plain Win32 process, from a plain
/// route, from inside a Flutter modal route with `window_manager`, `media_kit`
/// and a registered global hotkey, and from the fully bootstrapped app.
///
/// **So the log has to say the picker was asked for, and a bare `info` will not
/// do it.** `LogFileSink` queues behind a 400 ms timer that runs on this
/// isolate, so a line written just before a freeze is still in memory when the
/// user ends the process. That is why the affected run's log ends on an
/// ordinary line with no exception — which reads like a crash, and is not one.
/// The flush is the whole point of this indirection: a run that froze here
/// leaves an `opening` line on disk with no matching outcome line, which names
/// both the freeze and where it happened.
///
/// **What this cannot do.** Nothing on this isolate can time the picker out or
/// recover the frame: a `Timer` is a task for the thread that is already
/// blocked. The way out stays the field beside the button — every surface that
/// offers Browse also accepts a typed path.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../logging/diagnostics.dart';

/// The picker types a caller needs, so nothing outside this file has to import
/// `file_selector` and go round the announcement.
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

/// Asks the host for one file, announcing it first.
///
/// [what] is the thing being chosen, in the user's words — it is the only part
/// of the log line that says which of the app's Browse buttons was pressed.
Future<XFile?> pickOneFile({
  required String what,
  List<XTypeGroup> acceptedTypeGroups = const [],
  String? initialDirectory,
  @visibleForTesting ShowFileDialog show = openFile,
  @visibleForTesting Diagnostics? diagnostics,
}) async {
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
  }
}

/// Asks the host for one directory, announcing it first.
Future<String?> pickOneDirectory({
  required String what,
  String? confirmButtonText,
  String? initialDirectory,
  @visibleForTesting ShowDirectoryDialog show = getDirectoryPath,
  @visibleForTesting Diagnostics? diagnostics,
}) async {
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
  }
}

/// Logs that the picker is about to be shown, and gets that line onto disk
/// before it is — see the library comment. Awaited, not fired off: the point is
/// that the write has already happened by the time the picker takes the
/// isolate.
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

/// Returns null rather than rethrowing: three of the call sites had no catch at
/// all, so a picker the host refuses used to take the enclosing callback with
/// it and leave the form looking as though nothing had been pressed.
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
