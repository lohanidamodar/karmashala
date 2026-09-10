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
/// **So the isolate is asked to be still, not merely to be quick.** [
/// PickerQuiet] is announced at the same seam: anything that works on this
/// isolate while the user is looking at a picker registers there, is told to
/// stop before [openFile] is called and to carry on when the dialog has
/// answered — whichever way it answered, and even if it threw. The device
/// pane's live view is the first registrant, and it is the shape the rest
/// should copy: **pause, never tear down.** A subsystem that dropped its
/// connection for a dialog would trade a freeze for a reconnect.
///
/// **What this cannot do.** Nothing on this isolate can time the picker out or
/// recover the frame: a `Timer` is a task for the thread that is already
/// blocked. Nor is quieting a proof: the freeze reported on 2026-09-09 has no
/// `device-stream` line anywhere in its run, and a healthy stream logs nothing,
/// so the log neither convicts the live view nor clears it. The way out stays
/// the field beside the button — every surface that offers Browse also accepts
/// a typed path.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'package:karmashala_core/logging.dart';

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

/// Told `true` when a picker is about to be shown and `false` when it has
/// answered. Never called with the value it was last given.
typedef PickerQuietHook = void Function(bool quiet);

/// Everything on this isolate that must stop while a host dialog is being
/// created — see the library comment.
///
/// A registry rather than a call at each Browse button, because the rule is
/// about the *isolate*, not about the surface: the pane that is busy is rarely
/// the pane the user is picking from, and a later occupant should be covered by
/// registering rather than by every picker learning about it.
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

  /// Registers [hook] and returns the callback that removes it.
  ///
  /// A hook registered while a picker is already up is quieted immediately, and
  /// one removed while a picker is up is released: a subsystem must never be
  /// left stopped by a dialog it never heard finish.
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

  /// One registrant's failure is not the picker's problem, and above all is not
  /// a reason to leave the others quiet.
  void _tell(PickerQuietHook hook, bool quiet) {
    try {
      hook(quiet);
    } on Object catch (error, stack) {
      _logger.warning('a picker-quiet hook refused $quiet', error, stack);
    }
  }
}

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
  @visibleForTesting PickerQuiet? quiet,
}) async {
  // Before the announce, not between it and the call: the flush below yields to
  // the event loop, and whatever runs in that gap is already on the thread the
  // dialog is about to need.
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

/// Returns null rather than rethrowing. Counted at the move: of the eight
/// picker calls in the app, seven had no catch anywhere around them — only the
/// composer's image attach did — so a picker the host refuses used to take the
/// enclosing callback with it and leave the form looking as though nothing had
/// been pressed.
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
