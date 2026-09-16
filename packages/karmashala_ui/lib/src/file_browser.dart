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
/// shell namespace, COM or Network at all. See docs/SETTLED.md.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';
import 'desktop_dialog.dart';
import 'hidden_files.dart';
import 'hidden_files_chip.dart';
import 'inline_spinner.dart';

/// One row of a listed directory.
@immutable
class BrowsedEntry {
  const BrowsedEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.hidden = false,
  });

  final String name;
  final String path;
  final bool isDirectory;

  /// A leading dot, or the Windows hidden or system attribute. Read once while
  /// listing, so the toggle is a filter rather than a second walk of the disk.
  final bool hidden;
}

/// Lists one directory. A seam, so a test never touches a real disk.
typedef DirectoryLister = Future<List<BrowsedEntry>> Function(String path);

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
  return showDialog<String>(
    context: context,
    builder: (_) => FileBrowserDialog(
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
    ),
  );
}

/// The default [DirectoryLister]. Entries that cannot be classified are kept as
/// files: a row the user can see and refuse beats a row that vanished.
Future<List<BrowsedEntry>> listDirectory(String path) async {
  final entries = <BrowsedEntry>[];
  await for (final entity in Directory(path).list(followLinks: false)) {
    final name = _leafOf(entity.path);
    entries.add(
      BrowsedEntry(
        name: name,
        path: entity.path,
        isDirectory: entity is Directory,
        hidden: isHiddenEntry(name: name, path: entity.path),
      ),
    );
  }
  return entries;
}

Future<bool> _directoryExists(String path) async {
  try {
    return await Directory(path).exists();
  } on Object {
    return false;
  }
}

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
    super.key,
  });

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
  final _path = TextEditingController();
  final _filter = TextEditingController();
  final _listFocus = FocusNode();

  late String _directory;
  List<BrowsedEntry> _entries = const [];
  BrowsedEntry? _selected;
  String? _error;
  bool _loading = false;
  List<_Place> _places = const [];

  /// Which of the sources is open. Null when the caller gave none, which is
  /// this computer read through the widget's own lister.
  BrowseSource? _source;

  /// The dropdown is dead while a machine is answering: two switches in flight
  /// would race to say where the browser is standing.
  bool get _busySwitching => _loading && _entries.isEmpty;

  /// Guards against an earlier, slower listing landing after a later one.
  int _generation = 0;

  /// Where the browser has been this visit, and where in it we are standing.
  /// Walking back and opening a new folder from there drops what was ahead,
  /// the way a browser's own history does.
  final List<String> _trail = [];
  int _step = -1;

  @override
  void initState() {
    super.initState();
    _source = _initialSource();
    _directory = widget.startAt?.trim().isNotEmpty ?? false
        ? widget.startAt!.trim()
        : _homeOf(widget.environment);
    // A remote source has no start we can guess, so it is asked for one; a
    // local one opens immediately, because waiting on a round trip we do not
    // need is the whole complaint this browser exists to answer.
    if (_source != null && !_source!.local) {
      unawaited(_openHomeOf(_source!));
    } else {
      _open(_directory);
    }
    unawaited(_loadPlaces());
  }

  /// The source to open on: the one the caller named, else the first local one,
  /// else the first there is.
  BrowseSource? _initialSource() {
    if (widget.sources.isEmpty) return null;
    final named = widget.environmentId;
    for (final source in widget.sources) {
      if (source.id == named) return source;
    }
    for (final source in widget.sources) {
      if (source.local) return source;
    }
    return widget.sources.first;
  }

  DirectoryLister get _lister => _source?.lister ?? widget.lister;

  /// Moves to another machine. The trail does not cross: Back into a folder on
  /// a host you have left would read as this one's.
  Future<void> _switchTo(BrowseSource source) async {
    setState(() {
      _source = source;
      _trail.clear();
      _step = -1;
      _places = const [];
    });
    unawaited(_loadPlaces());
    await _openHomeOf(source);
  }

  Future<void> _openHomeOf(BrowseSource source) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _entries = const [];
    });
    try {
      final home = await source.home().timeout(kListingPatience);
      if (!mounted || generation != _generation) return;
      await _open(home);
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '${source.label} could not say where to start — $error';
      });
    }
  }

  @override
  void dispose() {
    _path.dispose();
    _filter.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  Future<void> _open(String path, {bool record = true}) async {
    if (record) {
      if (_step < _trail.length - 1) _trail.removeRange(_step + 1, _trail.length);
      _trail.add(path);
      _step = _trail.length - 1;
    }
    final generation = ++_generation;
    setState(() {
      _directory = path;
      _path.text = path;
      _loading = true;
      _error = null;
      _selected = null;
      _filter.clear();
    });
    try {
      final entries = await _lister(path).timeout(kListingPatience);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = _ordered(entries);
        _loading = false;
      });
    } on TimeoutException {
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = const [];
        _loading = false;
        _error =
            'This folder did not answer within '
            '${kListingPatience.inSeconds} seconds. A disconnected share or a '
            'stopped WSL distribution reads like this.';
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = const [];
        _loading = false;
        _error = _sentenceFor(error, path);
      });
    }
  }

  /// Folders first, then names — the order every file manager uses, so the eye
  /// does not have to learn a new one.
  List<BrowsedEntry> _ordered(List<BrowsedEntry> entries) {
    final kept = [
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
    return kept;
  }

  /// A folder picker shows no files at all; a file picker shows the extensions
  /// it was given, or everything when it was given none.
  bool _accepts(String name) {
    if (widget.directories) return false;
    final wanted = <String>{
      for (final group in widget.acceptedTypeGroups)
        ...?group.extensions?.map((e) => e.toLowerCase().replaceAll('.', '')),
    };
    if (wanted.isEmpty) return true;
    final cut = name.lastIndexOf('.');
    if (cut <= 0 || cut == name.length - 1) return false;
    return wanted.contains(name.substring(cut + 1).toLowerCase());
  }

  Future<void> _loadPlaces() async {
    // Only this computer's own drives and folders: a drive letter means nothing
    // on a host reached over SSH, and probing one would stat the wrong machine.
    final source = _source;
    if (source != null && !source.local) return;
    final places = await _shortcuts(widget.environment, widget.exists);
    if (!mounted) return;
    setState(() => _places = places);
  }

  /// One tap opens a folder — the row is the affordance, not a chevron on the
  /// end of it. A file is selected instead, because opening one is the answer.
  void _tapped(BrowsedEntry entry) {
    if (entry.isDirectory) {
      _open(entry.path);
    } else {
      setState(() => _selected = entry);
    }
  }

  /// What Choose returns: a folder picker answers with wherever the browser is
  /// standing — tapping a folder walks into it — and a file picker needs a file.
  String? get _answer {
    if (widget.directories) return _directory;
    final selected = _selected;
    return selected != null && !selected.isDirectory ? selected.path : null;
  }

  void _up() {
    final parent = _parentOf(_directory);
    if (parent != null) _open(parent);
  }

  bool get _canGoBack => _step > 0;
  bool get _canGoForward => _step >= 0 && _step < _trail.length - 1;

  void _back() {
    if (!_canGoBack) return;
    _step--;
    _open(_trail[_step], record: false);
  }

  void _forward() {
    if (!_canGoForward) return;
    _step++;
    _open(_trail[_step], record: false);
  }

  List<BrowsedEntry> get _visible {
    final needle = _filter.text.trim().toLowerCase();
    return [
      for (final entry in _entries)
        if (HiddenFilesPreference.shown || !entry.hidden)
          if (needle.isEmpty || entry.name.toLowerCase().contains(needle))
            entry,
    ];
  }

  /// How many rows the hidden toggle is currently keeping off screen — said out
  /// loud, so an empty-looking folder is never a mystery.
  int get _hiddenCount => _entries.where((entry) => entry.hidden).length;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final width = media.width * 0.92 < 760.0 ? media.width * 0.92 : 760.0;
    final height = media.height * 0.86 < 560.0 ? media.height * 0.86 : 560.0;
    // The shortcuts are the first thing to go: the listing is the dialog.
    final roomForPlaces = width >= 560;

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
            if (widget.sources.length > 1) ...[
              const SizedBox(height: Insets.md),
              _SourceBar(
                sources: widget.sources,
                current: _source,
                onChanged: _busySwitching ? null : _switchTo,
              ),
            ],
            const SizedBox(height: Insets.md),
            _PathBar(
              controller: _path,
              onBack: _canGoBack ? _back : null,
              onForward: _canGoForward ? _forward : null,
              onUp: _parentOf(_directory) == null ? null : _up,
              onRefresh: () => _open(_directory, record: false),
              onSubmitted: (value) {
                final trimmed = value.trim();
                if (trimmed.isNotEmpty) _open(trimmed);
              },
            ),
            const SizedBox(height: Insets.sm),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (roomForPlaces) ...[
                    SizedBox(
                      width: 168,
                      child: _Places(
                        places: _places,
                        current: _directory,
                        onTap: _open,
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                  ],
                  Expanded(child: _listing(context)),
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                Expanded(
                  child: _FilterField(
                    controller: _filter,
                    onChanged: (_) => setState(() {}),
                    hint: widget.directories
                        ? 'Filter folders'
                        : 'Filter this folder',
                  ),
                ),
                const SizedBox(width: Insets.sm),
                HiddenFilesChip(
                  hiddenCount: _hiddenCount,
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _answer == null
              ? null
              : () => Navigator.of(context).pop(_answer),
          child: Text(widget.confirmButtonText ?? 'Choose'),
        ),
      ],
    );
  }

  Widget _listing(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      side: BorderSide(color: scheme.outlineVariant),
    );

    final Widget body;
    if (_loading) {
      body = const Center(
        child: InlineSpinner(size: InlineSpinnerSize.large),
      );
    } else if (_error != null) {
      body = _Message(icon: AppIcons.warningCircle, text: _error!);
    } else {
      final rows = _visible;
      if (rows.isEmpty) {
        body = _Message(
          icon: AppIcons.folder,
          text: _entries.isEmpty
              ? (widget.directories
                    ? 'No folders in here. You can still choose this one.'
                    : 'Nothing in here matches what is being asked for.')
              : 'Nothing matches “${_filter.text.trim()}”.',
        );
      } else {
        body = Focus(
          focusNode: _listFocus,
          child: ListView.builder(
            primary: false,
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final entry = rows[index];
              return _EntryRow(
                entry: entry,
                selected: _selected?.path == entry.path,
                onTap: () => _tapped(entry),
              );
            },
          ),
        );
      }
    }

    return Material(
      color: scheme.surfaceContainerLowest,
      shape: border,
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }
}

/// Which machine is being browsed. Drawn only when there is a choice, so a
/// workspace with nothing but this computer keeps the plain dialog.
class _SourceBar extends StatelessWidget {
  const _SourceBar({
    required this.sources,
    required this.current,
    required this.onChanged,
  });

  final List<BrowseSource> sources;
  final BrowseSource? current;
  final ValueChanged<BrowseSource>? onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: current?.id ?? sources.first.id,
    decoration: const InputDecoration(isDense: true, labelText: 'Look in'),
    items: [
      for (final source in sources)
        DropdownMenuItem(
          value: source.id,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                source.local ? AppIcons.stack : AppIcons.globe,
                size: Chrome.icon,
              ),
              const SizedBox(width: Insets.sm),
              Text(source.label),
            ],
          ),
        ),
    ],
    onChanged: onChanged == null
        ? null
        : (id) {
            for (final source in sources) {
              if (source.id == id && source.id != current?.id) {
                onChanged!(source);
                return;
              }
            }
          },
  );
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.controller,
    required this.onBack,
    required this.onForward,
    required this.onUp,
    required this.onRefresh,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onUp;
  final VoidCallback onRefresh;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        onPressed: onBack,
        icon: const Icon(AppIcons.caretLeft, size: Chrome.icon),
        tooltip: 'Back',
      ),
      IconButton(
        onPressed: onForward,
        icon: const Icon(AppIcons.caretRight, size: Chrome.icon),
        tooltip: 'Forward',
      ),
      IconButton(
        onPressed: onUp,
        icon: const Icon(AppIcons.arrowUp, size: Chrome.icon),
        tooltip: 'Up one folder',
      ),
      Expanded(
        child: TextField(
          controller: controller,
          decoration: InputDecoration(
            isDense: true,
            hintText: Platform.isWindows
                ? r'C:\ or \\wsl.localhost\distro\home\you'
                : '/ or ~/projects',
          ),
          onSubmitted: onSubmitted,
        ),
      ),
      IconButton(
        onPressed: onRefresh,
        icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
        tooltip: 'Read this folder again',
      ),
    ],
  );
}

class _FilterField extends StatelessWidget {
  const _FilterField({
    required this.controller,
    required this.onChanged,
    required this.hint,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: true,
    decoration: InputDecoration(
      isDense: true,
      prefixIcon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
      hintText: hint,
    ),
    onChanged: onChanged,
  );
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final BrowsedEntry entry;
  final bool selected;
  final VoidCallback onTap;

  // No double-tap-to-open: a double-tap recognizer makes every *single* tap
  // wait out its timeout before it resolves, so selecting a file would lag by
  // 300 ms to save one click on Choose.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: StateLayers.selected(scheme),
      leading: Icon(
        entry.isDirectory ? AppIcons.folder : AppIcons.article,
        size: Chrome.icon,
        color: entry.isDirectory ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: entry.isDirectory
          ? Icon(
              AppIcons.caretRight,
              size: Chrome.icon,
              color: scheme.onSurfaceVariant,
            )
          : null,
    );
  }
}

class _Places extends StatelessWidget {
  const _Places({
    required this.places,
    required this.current,
    required this.onTap,
  });

  final List<_Place> places;
  final String current;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        primary: false,
        children: [
          for (final place in places)
            ListTile(
              dense: true,
              selected: place.path.toLowerCase() == current.toLowerCase(),
              leading: Icon(place.icon, size: Chrome.icon),
              title: Text(
                place.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onTap(place.path),
            ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: Chrome.iconHero,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class _Place {
  const _Place(this.label, this.path, this.icon);
  final String label;
  final String path;
  final IconData icon;
}

/// The shortcuts down the left: the user's own folders, then whatever drive
/// letters answer. **Network is never listed** — reaching it is the cost this
/// whole browser exists to avoid, and a drive letter is not the Network root.
Future<List<_Place>> _shortcuts(
  Map<String, String> environment,
  DirectoryExists exists,
) async {
  final home = _homeOf(environment);
  final candidates = <_Place>[
    _Place('Home', home, AppIcons.folderOpen),
    _Place('Desktop', _join(home, 'Desktop'), AppIcons.folder),
    _Place('Documents', _join(home, 'Documents'), AppIcons.folder),
    _Place('Downloads', _join(home, 'Downloads'), AppIcons.folder),
    if (Platform.isWindows)
      // A: and B: are floppy letters; probing them spins hardware that is not
      // there on the machines that still map them.
      for (var letter = 'C'.codeUnitAt(0);
          letter <= 'Z'.codeUnitAt(0);
          letter++)
        _Place(
          '${String.fromCharCode(letter)}:',
          '${String.fromCharCode(letter)}:\\',
          AppIcons.stack,
        ),
  ];

  final answered = await Future.wait([
    for (final place in candidates)
      exists(place.path).timeout(
        const Duration(milliseconds: 400),
        onTimeout: () => false,
      ),
  ]);
  return [
    for (var i = 0; i < candidates.length; i++)
      if (answered[i]) candidates[i],
  ];
}

String _homeOf(Map<String, String> environment) =>
    environment['USERPROFILE'] ??
    environment['HOME'] ??
    (Platform.pathSeparator == r'\' ? r'C:\' : '/');

String _join(String directory, String leaf) {
  final base = directory.replaceAll(RegExp(r'[\\/]+$'), '');
  return Platform.pathSeparator == r'\' ? '$base\\$leaf' : '$base/$leaf';
}

String _leafOf(String path) {
  final cleaned = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final cut = cleaned.lastIndexOf(RegExp(r'[\\/]'));
  return cut == -1 ? cleaned : cleaned.substring(cut + 1);
}

/// The parent of [path], or null at a root — a drive, a UNC share or `/`.
String? _parentOf(String path) {
  final trimmed = path.trim().replaceAll(RegExp(r'[\\/]+$'), '');
  if (trimmed.isEmpty) return null;
  if (RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) return null;
  final cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  if (cut <= 0) return null;
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

/// What went wrong, in the user's words. A path that refused is the ordinary
/// case and must not read like a crash.
String _sentenceFor(Object error, String path) {
  if (error is PathAccessException) {
    return 'Windows would not let this app read $path.';
  }
  if (error is PathNotFoundException) return 'There is no folder at $path.';
  if (error is FileSystemException) {
    final reason = error.osError?.message ?? error.message;
    return '$path could not be read — $reason.';
  }
  return '$path could not be read — $error.';
}
