/// One side of the file browser: where it is looking, what is there, what is
/// selected, and every operation the toolbar offers. A [ValueNotifier] rather
/// than a provider family because a panel's state belongs to the panel — it
/// dies with the tab, and nothing else has any business reading it.
library;

import 'package:agent_cli/process.dart';
import 'package:flutter/foundation.dart';
import 'package:karmashala_files/values.dart';

import '../data/files_client.dart';

/// What one panel is showing.
@immutable
class FilePanelState {
  const FilePanelState({
    this.directory,
    this.entries = const [],
    this.selected = const {},
    this.busy = false,
    this.error,
  });

  /// Where the panel is looking, or null before its first listing.
  final EnvironmentPath? directory;

  final List<FileEntry> entries;

  /// The paths of the selected entries. Paths, not indexes: a listing that
  /// comes back changed must not hand the selection to whatever moved up.
  final Set<String> selected;

  /// A listing or an operation is in flight.
  final bool busy;

  /// What went wrong, in the words the user is shown.
  final String? error;

  List<FileEntry> get selectedEntries => [
    for (final entry in entries)
      if (selected.contains(entry.path.path)) entry,
  ];

  FilePanelState copyWith({
    EnvironmentPath? directory,
    List<FileEntry>? entries,
    Set<String>? selected,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => FilePanelState(
    directory: directory ?? this.directory,
    entries: entries ?? this.entries,
    selected: selected ?? this.selected,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Drives one panel, on one machine the server reaches. Every verb leaves the
/// panel showing what is actually there: an operation is followed by a fresh
/// listing, so a rename that the filesystem refused cannot leave a row
/// renamed on screen.
class FilePanelController extends ValueNotifier<FilePanelState> {
  FilePanelController(this.files, this.environmentId)
    : super(const FilePanelState());

  final FilesClient files;
  final String environmentId;

  /// Only the newest listing may land: two quick double-clicks used to race,
  /// and the slower directory won.
  int _serial = 0;

  /// Opens [directory], or the machine's own starting folder when it is null.
  Future<void> open([EnvironmentPath? directory]) async {
    final serial = ++_serial;
    value = value.copyWith(busy: true, clearError: true);
    try {
      final target = directory ?? await files.home(environmentId);
      final resolved = (await files.resolve(target)).path;
      final entries = await files.list(resolved);
      if (serial != _serial) return;
      value = FilePanelState(directory: resolved, entries: entries);
    } on Object catch (error) {
      if (serial != _serial) return;
      value = value.copyWith(busy: false, error: _sentence(error));
    }
  }

  /// Lists the current directory again — after an operation, or because the
  /// user asked.
  Future<void> refresh() => open(value.directory);

  /// Goes to the folder above, if there is one.
  Future<void> goUp() async {
    final directory = value.directory;
    if (directory == null) return;
    final parent = parentOf(directory);
    if (parent == null) return;
    await open(parent);
  }

  /// Opens [entry] when it is a folder. A file is the caller's business: this
  /// panel does not decide what opening a file means.
  Future<void> enter(FileEntry entry) async {
    if (!entry.isDirectory) return;
    await open(entry.path);
  }

  /// Replaces the selection with [entry], or adds to it when [add].
  void select(FileEntry entry, {bool add = false}) {
    final path = entry.path.path;
    final selected = add ? {...value.selected} : <String>{};
    if (add && !selected.remove(path)) selected.add(path);
    if (!add) selected.add(path);
    value = value.copyWith(selected: selected);
  }

  void clearSelection() => value = value.copyWith(selected: const {});

  /// Forgets the last failure, so a dialog's message does not outlive it.
  void dismissError() => value = value.copyWith(clearError: true);

  Future<void> createFolder(String name) =>
      _operate((directory) => files.createDirectory(directory, name));

  Future<void> createFile(String name) =>
      _operate((directory) => files.createFile(directory, name));

  Future<void> rename(FileEntry entry, String name) =>
      _operate((_) => files.rename(entry.path, name));

  /// Deletes [entries]. A folder with anything in it needs [recursive], which
  /// is the caller's to ask for — and to have confirmed.
  Future<void> delete(List<FileEntry> entries, {bool recursive = false}) =>
      _operate((_) async {
        for (final entry in entries) {
          await files.delete(entry.path, recursive: recursive);
        }
        return null;
      });

  /// Runs one operation against the directory on screen, then lists it again.
  /// The listing is what the panel shows, so nothing is drawn that the
  /// filesystem did not do.
  Future<void> _operate(
    Future<EnvironmentPath?> Function(EnvironmentPath directory) body,
  ) async {
    final directory = value.directory;
    if (directory == null) return;
    value = value.copyWith(busy: true, clearError: true);
    EnvironmentPath? made;
    String? failure;
    try {
      made = await body(directory);
    } on Object catch (error) {
      failure = _sentence(error);
    }
    await open(directory);
    value = value.copyWith(
      error: failure,
      // What was just made is what the user is about to act on.
      selected: made == null ? const {} : {made.path},
    );
  }

  /// The sentence a panel shows. A [FilesException] already carries one;
  /// anything else is named rather than dressed up as something it is not.
  static String _sentence(Object error) => switch (error) {
    FilesException(:final message) => message,
    ArgumentError(:final message) => '$message',
    _ => error.toString(),
  };
}
