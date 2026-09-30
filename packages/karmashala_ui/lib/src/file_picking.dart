/// Every "Browse…" goes through here, for three reasons the log alone cannot
/// give: the picker is recorded *before* it is asked for, it is always handed
/// a live **local** starting directory, and this executable's shell
/// last-visited row is dropped first.
///
/// The third is not the second. A local `initialDirectory` chooses what the
/// dialog *shows*; it does not stop the dialog restoring its own
/// `LastVisitedPidlMRU` folder while it builds, and a `\\wsl.localhost` row
/// there costs an enumeration of Network — 30.3 s measured 2026-09-10, and a
/// process hung with `p9np.dll` loaded and no dialog window at all on
/// 2026-09-15. See [forgetLastVisitedFolder] and docs/SETTLED.md.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import 'package:karmashala_core/logging.dart';

import 'file_browser.dart';
import 'picker_last_visited.dart';

/// The picker types a caller needs, so nothing outside this file imports
/// `file_selector` and goes round the announcement.
export 'package:file_selector/file_selector.dart' show XFile, XTypeGroup;
export 'file_browser.dart'
    show
        BrowseSource,
        BrowseSources,
        BrowsedEntry,
        DirectoryExists,
        DirectoryLister,
        FileBrowserDialog,
        kListingPatience,
        listDirectory,
        showFileBrowser;
export 'picker_last_visited.dart'
    show forgetLastVisitedFolder, forgetRemoteRecentFolders;

/// Which dialog a "Browse…" opens, and who decides.
///
/// **Windows defaults to Karmashala's own browser** because the host's has been
/// measured failing to draw at all in this process (see [showFileBrowser]);
/// macOS and Linux default to the system dialog, which is the one their users
/// know and which has given no trouble. [prefersInApp] is the user's own
/// answer, installed by the app from settings.
class FilePickerChoice {
  const FilePickerChoice._();

  /// The user's preference, or null while they have expressed none.
  static bool Function()? prefersInApp;

  /// What this platform does when nobody has said otherwise.
  static bool get platformDefault => Platform.isWindows;

  /// A phone has no choice to make, so it offers none (owner, 2026-10-01):
  /// its own files open in the system picker, the one that reaches its
  /// photos and cloud drives, and the server's in Karmashala's, the only one
  /// that can see another machine's disk.
  static bool get isPhone => Platform.isAndroid || Platform.isIOS;

  /// Whether a pick of **the server's** files opens Karmashala's browser.
  static bool get inApp {
    if (isPhone) return true;
    try {
      return prefersInApp?.call() ?? platformDefault;
    } on Object {
      // A settings read that throws must not cost the user their picker.
      return platformDefault;
    }
  }

  /// The user's preference for **this device's** files, or null while unset.
  /// Separate from [prefersInApp], which a remote client forces to the server.
  static bool Function()? devicePrefersInApp;

  /// Whether a pick of **this device's** files opens Karmashala's browser.
  static bool get deviceInApp {
    if (isPhone) return false;
    try {
      return devicePrefersInApp?.call() ?? platformDefault;
    } on Object {
      return platformDefault;
    }
  }

  /// Whether the server's disk is this device's, installed by the app. While
  /// it is, a device pick is today's pick, unchanged: there is one disk.
  static bool Function()? serverOnThisDevice;

  static bool get deviceIsServer {
    try {
      return serverOnThisDevice?.call() ?? false;
    } on Object {
      return false;
    }
  }
}

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

/// Drops this executable's shell last-visited row. A seam, so a test never
/// spawns `reg.exe`.
@visibleForTesting
typedef ForgetLastVisited = Future<int> Function();

/// Drops the remote folders the shell offers as recent for these extensions.
@visibleForTesting
typedef ForgetRemoteRecent = Future<int> Function(List<String> extensions);

Future<int> _forgetRemoteRecent(List<String> extensions) =>
    forgetRemoteRecentFolders(extensions: extensions);

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

/// Asks for one file, announcing it first. [what] is the thing being chosen,
/// in the user's words — the only clue to which Browse was pressed.
/// [startNear] is where to open; see [pickerStartDirectory] for what happens
/// when it is null or is not somewhere we may start.
Future<XFile?> pickOneFile({
  required String what,
  BuildContext? context,
  String? environmentId,
  String? startNear,
  List<XTypeGroup> acceptedTypeGroups = const [],
  List<BrowseSource>? sources,
  @visibleForTesting ShowFileDialog show = openFile,
  @visibleForTesting ForgetLastVisited forget = forgetLastVisitedFolder,
  @visibleForTesting ForgetRemoteRecent forgetRemote = _forgetRemoteRecent,
  @visibleForTesting Diagnostics? diagnostics,
  @visibleForTesting PickerQuiet? quiet,
  @visibleForTesting DirectoryProbe probe = _directoryIsThere,
  @visibleForTesting Map<String, String>? environment,
  @visibleForTesting bool? inApp,
}) async {
  final start = pickerStartDirectory(
    startNear,
    probe: probe,
    environment: environment,
  );
  if (_inApp(inApp, context, environmentId)) {
    await _announce('file', what, start, diagnostics);
    // The flush above yields; a caller dismissed in that gap has no navigator.
    if (!context!.mounted) return null;
    final clock = Stopwatch()..start();
    try {
      final chosen = await showFileBrowser(
        context,
        what: what,
        directories: false,
        environmentId: environmentId,
        startAt: _startFor(environmentId, start, startNear),
        acceptedTypeGroups: acceptedTypeGroups,
        sources: sources,
      );
      _remember(chosen == null ? null : _parentOf(chosen));
      _report('file', what, chosen, clock);
      return chosen == null ? null : XFile(chosen);
    } on Object catch (error, stack) {
      _fail('file', what, clock, error, stack);
      return null;
    }
  }

  // Before the announce, not between it and the call: the flush below yields,
  // and whatever runs in that gap is already on the thread the dialog needs.
  final resume = (quiet ?? PickerQuiet.instance).begin();
  await forget();
  // And the *extension-keyed* list this filter will make the shell read; see
  // [forgetRemoteRecentFolders] for why the two lists are not one job.
  await forgetRemote([
    for (final group in acceptedTypeGroups) ...?group.extensions,
  ]);
  await _announce('file', what, start, diagnostics);
  final elapsed = Stopwatch()..start();
  try {
    final file = await show(
      acceptedTypeGroups: acceptedTypeGroups,
      // A phone's document picker has no folder to be pointed at, and the
      // `/` fallback means nothing to it.
      initialDirectory: Platform.isAndroid || Platform.isIOS ? null : start,
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

/// Asks for one file on **this device**, even when every other "Browse…" is
/// pointed at a server elsewhere: the in-app browser over this computer only,
/// or the host's dialog, as [FilePickerChoice.deviceInApp] says. While
/// [FilePickerChoice.deviceIsServer], exactly [pickOneFile].
Future<XFile?> pickDeviceFile({
  required String what,
  BuildContext? context,
  String? startNear,
  List<XTypeGroup> acceptedTypeGroups = const [],
}) {
  final elsewhere = !FilePickerChoice.deviceIsServer;
  return pickOneFile(
    what: what,
    context: context,
    startNear: startNear,
    acceptedTypeGroups: acceptedTypeGroups,
    sources: elsewhere ? const [] : null,
    inApp: elsewhere ? FilePickerChoice.deviceInApp : null,
  );
}

/// [pickDeviceFile] for a directory: somewhere on **this device** to write
/// to, whatever server the other "Browse…"es point at.
Future<String?> pickDeviceDirectory({
  required String what,
  BuildContext? context,
  String? startNear,
  String? confirmButtonText,
}) {
  final elsewhere = !FilePickerChoice.deviceIsServer;
  return pickOneDirectory(
    what: what,
    context: context,
    startNear: startNear,
    confirmButtonText: confirmButtonText,
    sources: elsewhere ? const [] : null,
    inApp: elsewhere ? FilePickerChoice.deviceInApp : null,
  );
}

/// Asks the host for one directory, announcing it first. [sources] narrows
/// the in-app browser's places, as for [pickOneFile].
Future<String?> pickOneDirectory({
  required String what,
  BuildContext? context,
  String? environmentId,
  String? startNear,
  String? confirmButtonText,
  List<BrowseSource>? sources,
  @visibleForTesting ShowDirectoryDialog show = getDirectoryPath,
  @visibleForTesting ForgetLastVisited forget = forgetLastVisitedFolder,
  @visibleForTesting Diagnostics? diagnostics,
  @visibleForTesting PickerQuiet? quiet,
  @visibleForTesting DirectoryProbe probe = _directoryIsThere,
  @visibleForTesting Map<String, String>? environment,
  @visibleForTesting bool? inApp,
}) async {
  final start = pickerStartDirectory(
    startNear,
    probe: probe,
    environment: environment,
  );
  if (_inApp(inApp, context, environmentId)) {
    await _announce('directory', what, start, diagnostics);
    if (!context!.mounted) return null;
    final clock = Stopwatch()..start();
    try {
      final chosen = await showFileBrowser(
        context,
        what: what,
        directories: true,
        environmentId: environmentId,
        startAt: _startFor(environmentId, start, startNear),
        confirmButtonText: confirmButtonText,
        sources: sources,
      );
      _remember(chosen);
      _report('directory', what, chosen, clock);
      return chosen;
    } on Object catch (error, stack) {
      _fail('directory', what, clock, error, stack);
      return null;
    }
  }

  final resume = (quiet ?? PickerQuiet.instance).begin();
  await forget();
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

/// Whether this call takes the in-app browser: it needs somewhere to draw, and
/// a test may say so outright.
///
/// A folder on another machine is **not** a preference. This computer's own
/// dialog cannot reach a distribution or a host, so a call that names one gets
/// the in-app browser whatever the user chose.
/// Whether this call takes the in-app browser. [forced] is a caller that has
/// no choice to offer — see the `inApp` parameter of [pickOneFile].
bool _inApp(bool? forced, BuildContext? context, String? environmentId) {
  if (context == null || !context.mounted) return false;
  return browsesInApp(environmentId, forced: forced);
}

/// Whether a "Browse…" pointed at [environmentId] opens **the app's own**
/// browser. [forced] is a caller that has already decided; [sources] and
/// [preference] are the seams a test stands in.
///
/// Another machine can only be browsed in the app — the host's dialog cannot
/// show a distribution or a host. **This** machine is not forced the other
/// way: naming the local environment used to send every "Browse…" that knew
/// where it was pointing to the host dialog, past the user's own setting and
/// past the Windows default — which is the freeze this library exists to
/// avoid, and it is what New Project's "Browse…" did.
bool browsesInApp(
  String? environmentId, {
  bool? forced,
  @visibleForTesting List<BrowseSource>? sources,
  @visibleForTesting bool? preference,
}) {
  if (forced != null) return forced;
  if (environmentId != null) {
    for (final source in sources ?? BrowseSources.all) {
      if (source.id == environmentId && !source.local) return true;
    }
  }
  return preference ?? FilePickerChoice.inApp;
}

/// Where to open when the browser is pointed at another machine. The local
/// fallback chain is about *this* computer's folders, so it is no answer for a
/// distribution or a host: those are left to the source's own home, unless the
/// caller's hint is already spelled for them.
String? _startFor(String? environmentId, String local, String? hint) {
  if (environmentId == null) return local;
  final spelled = hint?.trim();
  if (spelled == null || spelled.isEmpty) return null;
  return spelled;
}
