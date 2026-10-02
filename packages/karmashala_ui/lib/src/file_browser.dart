/// Karmashala's own file and folder browser, and why the desktop does not use
/// the host's.
///
/// Measured 2026-09-15 on a hung process, after the `\\wsl$` last-visited row
/// had been dropped and the network providers were no longer loading:
/// `IFileDialog::Show` had been entered — the owner window was already
/// `enabled=False` — **no `#32770` window was ever created**, and the UI thread
/// sat in a kernel wait that Wait Chain Traversal could attribute to no lock,
/// owner or cycle. The same dialog opened in 2.1 s in a plain process on the
/// same machine at the same moment, so the shell is well and our process is
/// not; `atcuf64.dll` and `bdhkm64.dll` were resident in it.
///
/// What that rules out is the point: nothing this app can pass the shell
/// dialog fixes it, because the failure is in code we do not run. This browser
/// asks `dart:io` instead, whose directory listing is asynchronous — so a slow
/// path costs a spinner rather than the UI thread — and never touches the
/// shell namespace, COM or Network at all.
///
/// The body is [FileBrowserView], driven by a [FileBrowserController]: the
/// same one the Files tab draws each side with and the phone's Files page
/// draws whole. This file is the pick around it — a dialog on a wide window,
/// a page on a narrow one.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';
import 'desktop_dialog.dart';
import 'file_browser_controller.dart';
import 'file_browser_view.dart';
import 'hidden_files.dart';

/// One row of a listed directory.
@immutable
class BrowsedEntry {
  const BrowsedEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.hidden = false,
    this.isLink = false,
    this.sizeBytes,
    this.readable = true,
  });

  final String name;
  final String path;
  final bool isDirectory;

  /// A leading dot, or the Windows hidden or system attribute. Read once while
  /// listing, so the toggle is a filter rather than a second walk of the disk.
  final bool hidden;

  /// A symbolic link the lister did not follow.
  final bool isLink;

  /// Null when the lister did not say — never 0 as a stand-in.
  final int? sizeBytes;

  /// False for a row listed but not statable — a device's `/` does this. The
  /// name is real, so it is shown, dimmed and inert.
  final bool readable;
}

/// Lists one directory. A seam, so a test never touches a real disk.
typedef DirectoryLister = Future<List<BrowsedEntry>> Function(String path);

/// Makes [name] inside [directory] and answers the new path. Throws with a
/// sentence a person can be shown when it was refused — a name taken, a
/// folder that will not be written.
typedef BrowseCreate = Future<String> Function(String directory, String name);

/// One place the browser can look — this computer, a WSL distribution, a host
/// over SSH. Every path a source produces is spelled for **its own** machine,
/// which is what the caller stores, so nothing here translates anything.
@immutable
class BrowseSource {
  const BrowseSource({
    required this.id,
    required this.label,
    required this.home,
    required this.lister,
    this.local = false,
    this.resolve,
    this.createDirectory,
    this.createFile,
    this.places,
  });

  /// The environment id, which is what a caller records alongside the path.
  final String id;

  /// How this place is named in the picker.
  final String label;

  /// Where to start. Asked lazily and once per visit: a remote home costs a
  /// round trip, and a source nobody opens must not pay for one.
  final Future<String> Function() home;

  final DirectoryLister lister;

  /// Whether this machine's own drives and user folders are worth offering as
  /// shortcuts. False for anything reached over a wire.
  final bool local;

  /// A typed path made absolute where it lives — `~` on a host means that
  /// host's home. Null takes a typed path as it is.
  final Future<String> Function(String path)? resolve;

  /// New folder and New file; null where this source cannot make them.
  final BrowseCreate? createDirectory;
  final BrowseCreate? createFile;

  /// This source's own shortcuts — a device's storage roots — in place of
  /// this computer's folders and drives.
  final Future<List<BrowsePlace>> Function()? places;
}

/// The places this app can browse, as the app knows them.
///
/// A static, for [PickerQuiet]'s reason: `karmashala_ui` must not depend on
/// environments, SSH or Riverpod, and every "Browse…" in the app should still
/// offer the same list. The app sets [lookup] once at start-up; until it does,
/// the browser is this computer only, which is what a test and the phone want.
class BrowseSources {
  const BrowseSources._();

  static List<BrowseSource> Function()? lookup;

  static List<BrowseSource> get all {
    try {
      return lookup?.call() ?? const [];
    } on Object {
      // A workspace that cannot enumerate its environments still gets a picker.
      return const [];
    }
  }
}

/// Whether a directory is reachable — used only to build the shortcuts.
typedef DirectoryExists = Future<bool> Function(String path);

/// How long a listing may take before the browser says so. A dead share is the
/// case this exists for: it must cost a sentence, never the window.
const Duration kListingPatience = Duration(seconds: 10);

/// How long a shortcut's folder may take to answer before it is left out — a
/// filesystem probe's patience, not motion.
const Duration kPlaceProbePatience = Duration(milliseconds: 400);

/// Shows the browser and returns the chosen path, or null when dismissed.
///
/// [directories] picks a folder — the confirm button then names wherever the
/// browser is standing, so an empty folder can be chosen without entering it.
Future<String?> showFileBrowser(
  BuildContext context, {
  required String what,
  required bool directories,
  String? startAt,
  List<XTypeGroup> acceptedTypeGroups = const [],
  String? confirmButtonText,
  String? environmentId,
  List<BrowseSource>? sources,
  @visibleForTesting DirectoryLister? lister,
  @visibleForTesting DirectoryExists? exists,
  @visibleForTesting Map<String, String>? environment,
}) {
  final places = sources ?? (lister == null ? BrowseSources.all : const []);
  // A phone's width has no room for a 760x560 dialog: a whole page instead.
  final fullScreen = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
  FileBrowserDialog browser(BuildContext _) => FileBrowserDialog(
    what: what,
    directories: directories,
    startAt: startAt,
    acceptedTypeGroups: acceptedTypeGroups,
    confirmButtonText: confirmButtonText,
    sources: places,
    environmentId: environmentId,
    lister: lister ?? listDirectory,
    exists: exists ?? _directoryExists,
    environment: environment ?? Platform.environment,
    fullScreen: fullScreen,
  );
  if (fullScreen) {
    return Navigator.of(
      context,
      rootNavigator: true,
    ).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: browser));
  }
  return showDialog<String>(context: context, builder: browser);
}

/// The default [DirectoryLister]. Entries that cannot be classified are kept as
/// files: a row the user can see and refuse beats a row that vanished.
Future<List<BrowsedEntry>> listDirectory(String path) async {
  final entries = <BrowsedEntry>[];
  await for (final entity in Directory(path).list(followLinks: false)) {
    final name = leafOfBrowsedPath(entity.path);
    entries.add(
      BrowsedEntry(
        name: name,
        path: entity.path,
        isDirectory: entity is Directory,
        isLink: entity is Link,
        hidden: isHiddenEntry(name: name, path: entity.path),
      ),
    );
  }
  return entries;
}

/// New folder on this computer's own disk, for a browser of it outside any
/// server. A name already there is refused, never reported made.
Future<String> createLocalDirectory(String directory, String name) async {
  final path = joinBrowsedPath(directory, name);
  if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
    throw StateError('There is already something called "$name" here.');
  }
  await Directory(path).create();
  return path;
}

/// [createLocalDirectory] for an empty file.
Future<String> createLocalFile(String directory, String name) async {
  final path = joinBrowsedPath(directory, name);
  if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
    throw StateError('There is already something called "$name" here.');
  }
  await File(path).create(exclusive: true);
  return path;
}

Future<bool> _directoryExists(String path) async {
  try {
    return await Directory(path).exists();
  } on Object {
    return false;
  }
}

/// The picker: [FileBrowserView] with a title and Choose, as a dialog — or,
/// [fullScreen], as a page with its own app bar and touch-sized rows.
class FileBrowserDialog extends StatefulWidget {
  const FileBrowserDialog({
    required this.what,
    required this.directories,
    required this.lister,
    required this.exists,
    required this.environment,
    this.sources = const [],
    this.environmentId,
    this.startAt,
    this.acceptedTypeGroups = const [],
    this.confirmButtonText,
    this.fullScreen = false,
    super.key,
  });

  /// Drawn as a page with its own app bar, with touch-sized rows, rather than
  /// a dialog: what a compact window gets.
  final bool fullScreen;

  final String what;
  final bool directories;
  final String? startAt;
  final List<XTypeGroup> acceptedTypeGroups;
  final String? confirmButtonText;

  /// Everywhere this browser may look. Empty means this computer alone, read
  /// through [lister].
  final List<BrowseSource> sources;

  /// Which of [sources] to open on, when the caller already has an opinion —
  /// the environment the field beside the button is spelled for.
  final String? environmentId;

  final DirectoryLister lister;
  final DirectoryExists exists;
  final Map<String, String> environment;

  @override
  State<FileBrowserDialog> createState() => _FileBrowserDialogState();
}

class _FileBrowserDialogState extends State<FileBrowserDialog> {
  late final FileBrowserController _browser = FileBrowserController(
    sources: widget.sources,
    environmentId: widget.environmentId,
    startAt: widget.startAt,
    directoriesOnly: widget.directories,
    acceptedTypeGroups: widget.acceptedTypeGroups,
    lister: widget.lister,
    exists: widget.exists,
    environment: widget.environment,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_browser.start());
  }

  @override
  void dispose() {
    _browser.dispose();
    super.dispose();
  }

  Widget _body({required bool touch}) => FileBrowserView(
    controller: _browser,
    touch: touch,
    // On a page the keyboard would cover the listing on arrival.
    autofocusFilter: !touch,
    // A "Browse…" asks for a file that exists: an empty one made here would
    // be chosen and handed to whatever wanted a real one.
    offerNewFile: false,
  );

  Widget _choose({required bool touch}) => ListenableBuilder(
    listenable: _browser,
    builder: (context, _) {
      final answer = _browser.answer;
      return FilledButton(
        style: touch
            ? FilledButton.styleFrom(minimumSize: const Size(0, Touch.target))
            : null,
        onPressed: answer == null
            ? null
            : () => Navigator.of(context).pop(answer),
        child: Text(widget.confirmButtonText ?? 'Choose'),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    if (widget.fullScreen) return _page(context);
    final media = MediaQuery.sizeOf(context);
    final width = media.width * 0.92 < 760.0 ? media.width * 0.92 : 760.0;
    final height = media.height * 0.86 < 560.0 ? media.height * 0.86 : 560.0;

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.lg,
        Insets.lg,
        0,
      ),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopDialogTitle(
              icon: widget.directories ? AppIcons.folderOpen : AppIcons.article,
              title: 'Choose ${widget.what}',
              subtitle: widget.directories
                  ? 'Open a folder to look inside it, or choose the one you '
                        'are standing in.'
                  : 'Type a path if you already know it.',
            ),
            const SizedBox(height: Insets.md),
            Expanded(child: _body(touch: false)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        _choose(touch: false),
      ],
    );
  }

  /// The browser as a page of its own: close and Choose in the app bar, the
  /// listing given the whole height and the shortcuts as a row of chips.
  Widget _page(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: Touch.appBarOf(context),
      leading: IconButton(
        tooltip: 'Cancel',
        icon: const Icon(AppIcons.x),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Text(
        'Choose ${widget.what}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: Insets.sm),
          child: _choose(touch: true),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.md),
        child: _body(touch: true),
      ),
    ),
  );
}

/// The user's home on this machine, or a root when the environment names none.
String homeOfEnvironment(Map<String, String> environment) =>
    environment['USERPROFILE'] ??
    environment['HOME'] ??
    (Platform.pathSeparator == r'\' ? r'C:\' : '/');

/// [leaf] inside [directory], in the separator [directory] is spelled with —
/// a POSIX path on a host stays POSIX on a Windows client.
String joinBrowsedPath(String directory, String leaf) {
  final base = directory.length > 1
      ? directory.replaceAll(RegExp(r'[\\/]+$'), '')
      : directory;
  final windows =
      RegExp(r'^[A-Za-z]:|\\').hasMatch(directory) ||
      (!directory.contains('/') && Platform.pathSeparator == r'\');
  if (base == '/' || base.isEmpty) return '/$leaf';
  return windows ? '$base\\$leaf' : '$base/$leaf';
}

String leafOfBrowsedPath(String path) {
  final cleaned = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final cut = cleaned.lastIndexOf(RegExp(r'[\\/]'));
  return cut == -1 ? cleaned : cleaned.substring(cut + 1);
}

/// The parent of [path], or null at a root — a drive, a UNC share or `/`.
String? parentOfBrowsedPath(String path) {
  final trimmed = path.trim().replaceAll(RegExp(r'[\\/]+$'), '');
  if (trimmed.isEmpty) return null;
  if (RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) return null;
  final cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  if (cut < 0) return null;
  // `/home` has `/` above it.
  if (cut == 0) return trimmed.startsWith('/') ? '/' : null;
  // `\\server\share` is a root: its parent would be the Network node.
  if (trimmed.startsWith(r'\\') || trimmed.startsWith('//')) {
    final segments = trimmed
        .replaceAll('/', r'\')
        .split(r'\')
        .where((s) => s.isNotEmpty);
    if (segments.length <= 2) return null;
  }
  final parent = trimmed.substring(0, cut);
  return RegExp(r'^[A-Za-z]:$').hasMatch(parent) ? '$parent\\' : parent;
}

/// What went wrong listing [path], in the user's words. A path that refused
/// is the ordinary case and must not read like a crash.
String listingFailureSentence(Object error, String path) {
  if (error is PathAccessException) {
    return 'Windows would not let this app read $path.';
  }
  if (error is PathNotFoundException) return 'There is no folder at $path.';
  if (error is StateError) return '$path could not be read — ${error.message}';
  if (error is FileSystemException) {
    final reason = error.osError?.message ?? error.message;
    return '$path could not be read — $reason.';
  }
  return '$path could not be read — $error.';
}

/// What went wrong making or changing something, in the user's words.
String operationFailureSentence(Object error) => switch (error) {
  StateError(:final message) => message,
  FileSystemException(:final osError, :final message) =>
    osError?.message ?? message,
  _ => '$error',
};
