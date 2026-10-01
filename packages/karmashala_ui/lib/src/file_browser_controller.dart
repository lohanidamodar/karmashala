/// What one file browser is looking at, for every browser in the app: the
/// picker, each side of the Files tab, and the phone's Files page.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/widgets.dart';

import 'app_icons.dart';
import 'file_browser.dart';
import 'hidden_files.dart';
import 'hidden_files_chip.dart';
import 'quick_access.dart';

/// One of the built-in shortcuts down the left: the user's own folders and the
/// drive letters that answer, on this machine only.
@immutable
class BrowsePlace {
  const BrowsePlace(this.label, this.path, this.icon);
  final String label;
  final String path;
  final IconData icon;
}

/// Drives one browser. A [ChangeNotifier] rather than a provider because a
/// browser's state belongs to the browser — it dies with the dialog or tab.
///
/// [multiSelect] is the Files tab's: a tap selects whatever it hits and
/// Ctrl-click adds to it. Without it a tap opens a folder and selects a file,
/// which is what a picker wants.
class FileBrowserController extends ChangeNotifier {
  FileBrowserController({
    List<BrowseSource> sources = const [],
    String? environmentId,
    String? startAt,
    this.directoriesOnly = false,
    this.acceptedTypeGroups = const [],
    this.multiSelect = false,
    DirectoryLister? lister,
    DirectoryExists? exists,
    Map<String, String>? environment,
  }) : _machines = sources,
       _requestedEnvironment = environmentId,
       _startAt = startAt?.trim(),
       _lister = lister ?? listDirectory,
       _exists = exists ?? _directoryExists,
       _environment = environment ?? Platform.environment {
    _source = _initialSource();
    _directory = _startAt?.isNotEmpty ?? false
        ? _startAt!
        : homeOfEnvironment(_environment);
  }

  final bool directoriesOnly;
  final List<XTypeGroup> acceptedTypeGroups;
  final bool multiSelect;

  final DirectoryLister _lister;
  final DirectoryExists _exists;
  final Map<String, String> _environment;
  final String? _requestedEnvironment;
  final String? _startAt;

  List<BrowseSource> _machines;
  BrowseSource? _source;
  late String _directory;
  List<BrowsedEntry> _entries = const [];
  Set<String> _selected = const {};
  String? _error;
  String? _notice;
  bool _loading = false;
  bool _working = false;
  List<BrowsePlace> _places = const [];
  bool _disposed = false;
  DateTime? _listedAt;

  /// Guards against an earlier, slower listing landing after a later one.
  int _generation = 0;

  /// Where the browser has been this visit, and where in it we are standing.
  /// Walking back and opening a new folder from there drops what was ahead,
  /// the way a browser's own history does.
  final List<String> _trail = [];
  int _step = -1;

  /// Everywhere this browser may look. Empty means this computer alone, read
  /// through the lister it was given.
  List<BrowseSource> get sources => _machines;

  /// Which of [sources] is open; null with none, which is this computer.
  BrowseSource? get source => _source;

  /// The environment a path here is spelled for, or null for a browser of
  /// this device's own disk outside any server — which nothing can pin.
  String? get environmentId => _source?.id;

  String get directory => _directory;
  List<BrowsedEntry> get entries => _entries;
  Set<String> get selected => _selected;

  /// The folder could not be listed, in the user's words; replaces the rows.
  String? get error => _error;

  /// An operation did not happen, in the user's words; shown above the rows.
  String? get notice => _notice;

  bool get loading => _loading;

  /// A New folder or New file is in flight.
  bool get working => _working;

  /// The built-in shortcuts, on this machine only.
  List<BrowsePlace> get places => _places;

  /// The source switch is dead while a machine is answering: two switches in
  /// flight would race to say where the browser is standing.
  bool get busySwitching => _loading && _entries.isEmpty;

  bool get canGoBack => _step > 0;
  bool get canGoForward => _step >= 0 && _step < _trail.length - 1;
  bool get canGoUp => parentOfBrowsedPath(_directory) != null;

  /// Whether New folder and New file have somewhere to go.
  bool get canCreate =>
      _source == null ? true : _source!.createDirectory != null;

  List<BrowsedEntry> get selectedEntries => [
    for (final entry in _entries)
      if (_selected.contains(entry.path)) entry,
  ];

  /// What a picker's Choose returns: a folder picker answers with wherever
  /// the browser is standing — tapping a folder walks into it — and a file
  /// picker needs a file.
  String? get answer {
    if (directoriesOnly) return _directory;
    for (final entry in _entries) {
      if (!entry.isDirectory && _selected.contains(entry.path)) {
        return entry.path;
      }
    }
    return null;
  }

  /// The rows the hidden toggle and [filter] leave on screen.
  List<BrowsedEntry> visible(String filter) {
    final needle = filter.trim().toLowerCase();
    return [
      for (final entry in _entries)
        if (HiddenFilesPreference.shown || !entry.hidden)
          if (needle.isEmpty || entry.name.toLowerCase().contains(needle))
            entry,
    ];
  }

  /// How many rows the hidden toggle is keeping off screen — said out loud,
  /// so an empty-looking folder is never a mystery.
  int get hiddenCount => _entries.where((entry) => entry.hidden).length;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Opens where the browser starts: the caller's folder when it named one,
  /// else the source's own home — asked for, because a remote home costs a
  /// round trip — or this computer's. A start that will not list on another
  /// machine falls back to that machine's home rather than an error.
  Future<void> start() async {
    unawaited(_loadPlaces());
    final source = _source;
    final start = _startAt;
    if (start != null && start.isNotEmpty) {
      // Loading from the first frame, or the resolve's round trip draws an
      // empty folder. Unannounced: this runs from an `initState`.
      _loading = true;
      await _open(await _resolved(start));
      if (_error != null && source != null && !source.local) {
        await _openHomeOf(source);
      }
      return;
    }
    if (source != null && !source.local) {
      await _openHomeOf(source);
    } else {
      await _open(_directory);
    }
  }

  /// The source to open on: the one the caller named, else the first local
  /// one, else the first there is.
  BrowseSource? _initialSource() {
    if (_machines.isEmpty) return null;
    for (final source in _machines) {
      if (source.id == _requestedEnvironment) return source;
    }
    for (final source in _machines) {
      if (source.local) return source;
    }
    return _machines.first;
  }

  DirectoryLister get _listing => _source?.lister ?? _lister;

  /// Replaces the machines this browser may look at — the workspace found or
  /// lost one. The one open stays open while it is still offered.
  void updateSources(List<BrowseSource> sources) {
    _machines = sources;
    final open = _source;
    if (open == null) return;
    for (final source in sources) {
      if (source.id == open.id) {
        _source = source;
        return;
      }
    }
    // Not now: this is called from a build, and a switch redraws.
    if (sources.isNotEmpty) {
      unawaited(Future(() => _disposed ? null : switchTo(sources.first)));
    }
  }

  /// Moves to another machine, at its home or at [at]. The trail does not
  /// cross: Back into a folder on a host you have left would read as this
  /// one's.
  Future<void> switchTo(BrowseSource source, {String? at}) async {
    _source = source;
    _trail.clear();
    _step = -1;
    _places = const [];
    _changed();
    unawaited(_loadPlaces());
    if (at != null) {
      await _open(at);
    } else {
      await _openHomeOf(source);
    }
  }

  Future<void> _openHomeOf(BrowseSource source) async {
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _entries = const [];
    _changed();
    try {
      final home = await source.home().timeout(kListingPatience);
      if (_disposed || generation != _generation) return;
      await _open(home);
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      _loading = false;
      _error = '${source.label} could not say where to start — $error';
      _changed();
    }
  }

  /// Opens a path the person typed: made absolute by the source when it can,
  /// so `~` or a relative path means what it would mean there.
  Future<void> openTyped(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;
    await _open(await _resolved(trimmed));
  }

  Future<String> _resolved(String path) async {
    final resolve = _source?.resolve;
    if (resolve == null) return path;
    try {
      return await resolve(path).timeout(kListingPatience);
    } on Object {
      // The listing says what is wrong with it, in its own words.
      return path;
    }
  }

  Future<void> open(String path) => _open(path);

  Future<void> _open(String path, {bool record = true}) async {
    if (record) {
      if (_step < _trail.length - 1) {
        _trail.removeRange(_step + 1, _trail.length);
      }
      _trail.add(path);
      _step = _trail.length - 1;
    }
    final generation = ++_generation;
    _directory = path;
    _loading = true;
    _error = null;
    _notice = null;
    _selected = const {};
    _changed();
    try {
      final entries = await _listing(path).timeout(kListingPatience);
      if (_disposed || generation != _generation) return;
      _entries = _ordered(entries);
      _loading = false;
      _listedAt = DateTime.now();
      _changed();
    } on TimeoutException {
      if (_disposed || generation != _generation) return;
      _entries = const [];
      _loading = false;
      _error =
          'This folder did not answer within '
          '${kListingPatience.inSeconds} seconds. A disconnected share or a '
          'stopped WSL distribution reads like this.';
      _changed();
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      _entries = const [];
      _loading = false;
      _error = listingFailureSentence(error, path);
      _changed();
    }
  }

  /// Lists the folder on screen again, with the spinner: Refresh.
  Future<void> refresh() => _open(_directory, record: false);

  /// Lists the folder on screen again **in place**, keeping whatever of the
  /// selection is still there — after this app changed it, on focus, or when
  /// the link to the server came back. Nothing happens while a listing runs.
  Future<void> relist() async {
    if (_disposed || _loading) return;
    final generation = ++_generation;
    final directory = _directory;
    try {
      final entries = await _listing(directory).timeout(kListingPatience);
      if (_disposed || generation != _generation) return;
      _entries = _ordered(entries);
      _listedAt = DateTime.now();
      final there = {for (final entry in _entries) entry.path};
      _selected = _selected.where(there.contains).toSet();
      _error = null;
      _changed();
    } on Object {
      // Refresh, focus or the next operation lists it again.
    }
  }

  /// [relist], when [directory] on [sourceId] is what is on screen.
  void relistIf(String sourceId, String directory) {
    if (_source?.id != sourceId) return;
    if (pinnedFolderKey(directory) != pinnedFolderKey(_directory)) return;
    unawaited(relist());
  }

  /// [relist], unless the folder was listed less than [floor] ago — a window
  /// flicking in and out of focus must not re-list over 9p or SSH.
  void relistUnlessFresh(Duration floor) {
    final at = _listedAt;
    if (at != null && DateTime.now().difference(at) < floor) return;
    unawaited(relist());
  }

  void back() {
    if (!canGoBack) return;
    _step--;
    unawaited(_open(_trail[_step], record: false));
  }

  void forward() {
    if (!canGoForward) return;
    _step++;
    unawaited(_open(_trail[_step], record: false));
  }

  void up() {
    final parent = parentOfBrowsedPath(_directory);
    if (parent != null) unawaited(_open(parent));
  }

  /// One tap. In a picker a folder opens — the row is the affordance, not a
  /// chevron on the end of it — and a file is selected, because opening one
  /// is the answer. In the Files tab a tap selects whatever it hits; [add]
  /// (Ctrl-click) adds to the selection instead.
  void tap(BrowsedEntry entry, {bool add = false}) {
    if (!entry.readable) return;
    if (!multiSelect && entry.isDirectory) {
      unawaited(_open(entry.path));
      return;
    }
    select(entry, add: add && multiSelect);
  }

  /// Replaces the selection with [entry], or toggles it in when [add].
  void select(BrowsedEntry entry, {bool add = false}) {
    final next = add ? {..._selected} : <String>{};
    if (add && next.contains(entry.path)) {
      next.remove(entry.path);
    } else {
      next.add(entry.path);
    }
    _selected = next;
    _changed();
  }

  void clearSelection() {
    _selected = const {};
    _changed();
  }

  /// Says why an operation the caller ran did not happen, above the rows.
  void showNotice(String? sentence) {
    _notice = sentence;
    _changed();
  }

  /// Makes a folder [name] where the browser stands and answers its path, or
  /// null when it was refused (the notice says why). A folder picker walks
  /// into it, so Choose answers it; anywhere else it is selected.
  Future<String?> createFolder(String name) => _create(name, folder: true);

  /// [createFolder] for an empty file, which is then selected.
  Future<String?> createFile(String name) => _create(name, folder: false);

  Future<String?> _create(String name, {required bool folder}) async {
    final source = _source;
    final make = source == null
        ? (folder ? createLocalDirectory : createLocalFile)
        : (folder ? source.createDirectory : source.createFile);
    if (make == null) return null;
    final directory = _directory;
    _working = true;
    _notice = null;
    _changed();
    String? made;
    try {
      made = await make(directory, name.trim());
    } on Object catch (error) {
      _notice = operationFailureSentence(error);
    }
    _working = false;
    if (_disposed) return made;
    if (made == null) {
      _changed();
      return null;
    }
    if (folder && directoriesOnly) {
      await _open(made);
      return made;
    }
    await relist();
    if (_entries.any((entry) => entry.path == made)) {
      _selected = {made};
    }
    _changed();
    return made;
  }

  /// A pick's own rule: a folder picker shows no files at all; a file picker
  /// shows the extensions it was given, or everything when it was given none.
  bool _accepts(String name) {
    if (directoriesOnly) return false;
    final wanted = <String>{
      for (final group in acceptedTypeGroups)
        ...?group.extensions?.map((e) => e.toLowerCase().replaceAll('.', '')),
    };
    if (wanted.isEmpty) return true;
    final cut = name.lastIndexOf('.');
    if (cut <= 0 || cut == name.length - 1) return false;
    return wanted.contains(name.substring(cut + 1).toLowerCase());
  }

  /// Folders first, then names — the order every file manager uses.
  List<BrowsedEntry> _ordered(List<BrowsedEntry> entries) =>
      [
        for (final entry in entries)
          if (entry.isDirectory || _accepts(entry.name)) entry,
      ]..sort(
        (a, b) => compareBrowsedRows(
          aIsDirectory: a.isDirectory,
          aName: a.name,
          bIsDirectory: b.isDirectory,
          bName: b.name,
        ),
      );

  Future<void> _loadPlaces() async {
    // Only this computer's own drives and folders: a drive letter means
    // nothing on a host reached over SSH, and probing one would stat the
    // wrong machine.
    final source = _source;
    final own = source?.places;
    if (own == null && source != null && !source.local) return;
    List<BrowsePlace> places;
    try {
      places = own != null
          ? await own()
          : await localShortcuts(_environment, _exists);
    } on Object {
      places = const [];
    }
    if (_disposed || _source?.id != source?.id) return;
    _places = places;
    _changed();
  }
}

Future<bool> _directoryExists(String path) async {
  try {
    return await Directory(path).exists();
  } on Object {
    return false;
  }
}

/// The shortcuts down the left: the user's own folders, then whatever drive
/// letters answer. **Network is never listed** — reaching it is the cost the
/// in-app browser exists to avoid, and a drive letter is not the Network root.
Future<List<BrowsePlace>> localShortcuts(
  Map<String, String> environment,
  DirectoryExists exists,
) async {
  final home = homeOfEnvironment(environment);
  final candidates = <BrowsePlace>[
    BrowsePlace('Home', home, AppIcons.folderOpen),
    BrowsePlace('Desktop', joinBrowsedPath(home, 'Desktop'), AppIcons.folder),
    BrowsePlace(
      'Documents',
      joinBrowsedPath(home, 'Documents'),
      AppIcons.folder,
    ),
    BrowsePlace(
      'Downloads',
      joinBrowsedPath(home, 'Downloads'),
      AppIcons.folder,
    ),
    if (Platform.isWindows)
      // A: and B: are floppy letters; probing them spins hardware that is not
      // there on the machines that still map them.
      for (
        var letter = 'C'.codeUnitAt(0);
        letter <= 'Z'.codeUnitAt(0);
        letter++
      )
        BrowsePlace(
          '${String.fromCharCode(letter)}:',
          '${String.fromCharCode(letter)}:\\',
          AppIcons.stack,
        ),
  ];

  final answered = await Future.wait([
    for (final place in candidates)
      exists(
        place.path,
      ).timeout(kPlaceProbePatience, onTimeout: () => false),
  ]);
  return [
    for (var i = 0; i < candidates.length; i++)
      if (answered[i]) candidates[i],
  ];
}
