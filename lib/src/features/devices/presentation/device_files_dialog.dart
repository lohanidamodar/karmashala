import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/clipboard/host_clipboard.dart';
import '../../../core/util/file_picking.dart';
import '../application/device_file_actions.dart';
import '../application/device_fleet.dart';
import 'package:karmashala_devices/devices.dart';

/// Browsing a device's storage, and moving files across.
///
/// **A list of roots, not a filesystem.** The driver says which roots it can
/// reach and this draws exactly those — see `domain/device_files.dart`. Android
/// has a real tree plus app-private directories; a real iOS device has only
/// the containers of development-signed apps, and a simulator is a directory on
/// the host. A picker that started at `/` would be lying on two of those three.
///
/// **A directory it cannot read says so.** `DeviceDirectoryListing` carries a
/// `note` for the refusal and `skipped` for lines the parser could not read,
/// and both are drawn. Most of `/data` is unreadable without root, and an empty
/// folder that is really a refusal is the failure this whole surface is built
/// to avoid: it reads as "nothing here" and sends the user looking elsewhere.
///
/// Every call is a subprocess, so every call is awaited and the dialog draws a
/// progress state rather than freezing. Nothing here runs on the platform
/// thread.
///
/// ## Two clipboards, kept apart on purpose
///
/// **The app's own**, holding device paths — what Copy and Cut fill and what
/// Paste empties. Those paths are moved by the *device*, with no host round
/// trip, so pasting a 2 GB video into the next folder costs one `cp` rather
/// than two transfers. It is deliberately not the system clipboard:
/// `/sdcard/DCIM/a.jpg` means nothing to any other program on this computer,
/// and putting it there as text would silently replace whatever the user had
/// copied with a string nothing can open.
///
/// **This computer's**, holding real files — which is how a file crosses
/// between here and the phone in either direction: *Copy for this computer*
/// stages a file under the system temp directory and puts its path on the
/// system file clipboard, so it pastes into Explorer; *Paste from this
/// computer* reads that clipboard and pushes what is on it. See
/// `application/device_file_actions.dart`.
///
/// **Dragging a row onto a folder** is the same device-side move, as a gesture.
/// `pointerDragAnchorStrategy` is not optional there: without it
/// `DragTargetDetails.offset` is the *feedback widget's* top-left rather than
/// the pointer, so a drop lands on whichever row happens to be under the
/// corner of the label.
///
/// **What this cannot do: drag a file to or from Explorer.** A drop from
/// outside needs a native `IDropTarget` and a drag out needs a native drag
/// source; neither is in this app's dependencies, and adding a C++ plugin is
/// exactly what `pubspec.yaml` already has two stubs for after the VS 2026
/// toolchain dropped ATL. The clipboard route above is the same operation
/// without a plugin.
class DeviceFilesDialog extends ConsumerStatefulWidget {
  const DeviceFilesDialog({
    required this.device,
    this.host = const PlatformHostClipboard(),
    this.temporaryDirectory,
    this.makeDirectory = makeHostDirectory,
    super.key,
  });

  final AndroidDevice device;

  /// This computer's clipboard, behind its seam so a test never reaches the
  /// platform channel.
  final HostClipboard host;

  /// Where a file copied off the device is staged. Defaults to the system temp
  /// directory, read lazily so nothing touches the filesystem at construction.
  final String? temporaryDirectory;

  /// Creates the staging directory.
  ///
  /// A seam for the same reason [host] is one, and a sharper one than it looks:
  /// a widget test body runs inside `FakeAsync`, so a real `Directory.create`
  /// never completes there and the symptom is `pumpAndSettle timed out` rather
  /// than anything about the filesystem.
  final HostDirectoryMaker makeDirectory;

  static Future<void> show(BuildContext context, AndroidDevice device) =>
      showDialog<void>(
        context: context,
        builder: (_) => DeviceFilesDialog(device: device),
      );

  @override
  ConsumerState<DeviceFilesDialog> createState() => _DeviceFilesDialogState();
}

class _DeviceFilesDialogState extends ConsumerState<DeviceFilesDialog> {
  DeviceDriver? _driver;
  List<DeviceFileRoot> _roots = const [];
  DeviceFileRoot? _root;
  String? _path;
  DeviceDirectoryListing? _listing;

  /// A refusal, in the device's own terms. Separate from [_listing] because a
  /// refusal is not an empty directory and must never be drawn as one.
  String? _refusal;
  String? _busy;

  /// Device paths held by Copy or Cut, or null when nothing is held.
  DeviceFileClipboard? _clip;

  String get _temporaryDirectory =>
      widget.temporaryDirectory ?? Directory.systemTemp.path;

  @override
  void initState() {
    super.initState();
    _openRoots();
  }

  Future<void> _openRoots() async {
    setState(() => _busy = 'Asking the device what it can reach…');
    try {
      final fleet = await ref.read(deviceFleetProvider)();
      final driver = fleet.driverForTarget(AndroidTarget(widget.device));
      final roots = await driver.fileRoots();
      if (!mounted) return;
      _driver = driver;
      _roots = roots;
      if (roots.isEmpty) {
        setState(() {
          _busy = null;
          _refusal = 'This device reports no storage this build can reach.';
        });
        return;
      }
      await _go(roots.first, roots.first.path);
    } on DeviceRefusal catch (refusal) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _refusal = refusal.toString();
      });
    }
  }

  /// Lists [path], recording a refusal as a refusal rather than as emptiness.
  Future<void> _go(DeviceFileRoot root, String path) async {
    final driver = _driver;
    if (driver == null) return;
    setState(() {
      _busy = 'Reading $path…';
      _refusal = null;
      _root = root;
      _path = path;
    });
    try {
      final listing = await driver.listDirectory(path);
      if (!mounted) return;
      setState(() {
        _busy = null;
        _listing = listing;
      });
    } on DeviceRefusal catch (refusal) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _listing = null;
        _refusal = refusal.toString();
      });
    }
  }

  Future<void> _pull(DeviceFileEntry entry) async {
    final driver = _driver;
    if (driver == null) return;
    // A directory to save into, not a save dialog: `file_selector`'s save
    // sheet is the one piece of this that is not dependable on every desktop,
    // and the app already asks for a directory in two other places.
    final directory = await pickOneDirectory(
      what: 'where to save ${entry.name}',
      confirmButtonText: 'Save here',
    );
    if (directory == null || !mounted) return;
    setState(() => _busy = 'Copying ${entry.name} to this computer…');
    try {
      final moved = await driver.pullFile(
        devicePath: entry.path,
        hostPath: p.join(directory, entry.name),
      );
      if (!mounted) return;
      setState(() => _busy = null);
      _say('Saved to ${moved.hostPath}${moved.note == null ? '' : ' · ${moved.note}'}');
    } on DeviceRefusal catch (refusal) {
      if (!mounted) return;
      setState(() => _busy = null);
      _say('$refusal');
    }
  }

  Future<void> _push() async {
    final driver = _driver;
    final path = _path;
    if (driver == null || path == null) return;
    final file = await pickOneFile(what: 'a file to copy to the device');
    if (file == null || !mounted) return;
    setState(() => _busy = 'Copying ${file.name} to the device…');
    try {
      final moved = await driver.pushFile(
        hostPath: file.path,
        devicePath: p.posix.join(path, file.name),
      );
      if (!mounted) return;
      setState(() => _busy = null);
      _say(moved.note ?? 'Copied to ${moved.devicePath}');
      await _go(_root!, path);
    } on DeviceRefusal catch (refusal) {
      if (!mounted) return;
      setState(() => _busy = null);
      // The refusal a push is *meant* to give: an existing file, not replaced.
      _say('$refusal');
    }
  }

  /// Holds [entry] on the app's own clipboard, to be pasted somewhere on the
  /// same device.
  void _hold(DeviceFileEntry entry, DeviceFileClipboardMode mode) {
    setState(() {
      _clip = DeviceFileClipboard(
        serial: widget.device.serial,
        entries: [entry],
        mode: mode,
      );
    });
    _say('${mode.label} ${entry.name}. Open a folder and press Paste.');
  }

  /// Pastes what the app is holding into [directory], on the device.
  Future<void> _paste(String directory) async {
    final driver = _driver;
    final clip = _clip;
    if (driver == null || clip == null) return;
    setState(() => _busy = '${clip.summary} into $directory…');
    final report = await pasteOnDevice(
      driver: driver,
      clip: clip,
      directory: directory,
    );
    if (!mounted) return;
    setState(() {
      _busy = null;
      // A cut is consumed by its paste; a copy survives so it can go into
      // several folders. `afterPaste` owns that rule.
      if (report.deviceChanged) _clip = clip.afterPaste();
    });
    _say(report.message);
    if (report.deviceChanged) await _refresh();
  }

  /// Copies [entry] off the device and onto **this computer's** clipboard, so
  /// it can be pasted into Explorer or Finder.
  Future<void> _copyForHost(DeviceFileEntry entry) async {
    final driver = _driver;
    if (driver == null) return;
    setState(() => _busy = 'Copying ${entry.name} to this computer…');
    final report = await copyToHostClipboard(
      driver: driver,
      host: widget.host,
      temporaryDirectory: _temporaryDirectory,
      entries: [entry],
      makeDirectory: widget.makeDirectory,
    );
    if (!mounted) return;
    setState(() => _busy = null);
    _say(report.message);
  }

  /// Pushes whatever files are on **this computer's** clipboard into the open
  /// directory: the other half of [_copyForHost].
  Future<void> _pasteFromHost() async {
    final driver = _driver;
    final path = _path;
    if (driver == null || path == null) return;
    setState(() => _busy = 'Copying this computer\'s clipboard to the device…');
    final report = await pasteFromHostClipboard(
      driver: driver,
      host: widget.host,
      directory: path,
    );
    if (!mounted) return;
    setState(() => _busy = null);
    _say(report.message);
    if (report.deviceChanged) await _refresh();
  }

  /// Drops [entry] into [directory] — the drag gesture for a device-side move.
  ///
  /// A move rather than a copy, which is what dragging within one filesystem
  /// means everywhere else. The app's own clipboard is left alone: a drag is
  /// not a cut, and clobbering a held Copy because somebody dragged something
  /// would lose work they had queued.
  Future<void> _dropInto(DeviceFileEntry entry, String directory) async {
    final driver = _driver;
    if (driver == null) return;
    final clip = DeviceFileClipboard(
      serial: widget.device.serial,
      entries: [entry],
      mode: DeviceFileClipboardMode.cut,
    );
    setState(() => _busy = 'Moving ${entry.name} into $directory…');
    final report = await pasteOnDevice(
      driver: driver,
      clip: clip,
      directory: directory,
    );
    if (!mounted) return;
    setState(() => _busy = null);
    _say(report.message);
    if (report.deviceChanged) await _refresh();
  }

  /// Re-reads the open directory. Its own method because five actions end with
  /// it and each was re-deriving the root.
  Future<void> _refresh() async {
    final root = _root;
    final path = _path;
    if (root == null || path == null) return;
    await _go(root, path);
  }

  /// Deleting, which nothing on the far side can undo.
  Future<void> _delete(DeviceFileEntry entry) async {
    final driver = _driver;
    final path = _path;
    if (driver == null || path == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(
          entry.isDirectory
              ? 'This removes the directory and everything in it, on the '
                    'device. There is no undo.'
              : 'This removes the file on the device. There is no undo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = 'Deleting ${entry.name}…');
    try {
      await driver.deletePath(entry.path, recursive: entry.isDirectory);
      if (!mounted) return;
      setState(() => _busy = null);
      await _go(_root!, path);
    } on DeviceRefusal catch (refusal) {
      if (!mounted) return;
      setState(() => _busy = null);
      _say('$refusal');
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  bool get _atRoot => _path == null || _path == _root?.path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text('Files on ${widget.device.displayName}'),
      contentPadding: const EdgeInsets.symmetric(vertical: Insets.sm),
      content: SizedBox(
        width: 620,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_roots.length > 1) _rootPicker(theme),
            _breadcrumb(theme),
            const Divider(height: 1),
            Expanded(child: _body(theme, scheme)),
            if (_busy case final busy?) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.md,
                  Insets.sm,
                  Insets.md,
                  0,
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(busy, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_writable && _path != null)
          TextButton.icon(
            key: const Key('device-files-paste-from-host'),
            onPressed: _busy == null ? _pasteFromHost : null,
            icon: const Icon(AppIcons.clipboardText, size: Chrome.iconAction),
            label: const Text('Paste from this computer'),
          ),
        if (_writable && _path != null)
          TextButton.icon(
            onPressed: _busy == null ? _push : null,
            icon: const Icon(AppIcons.plus, size: Chrome.iconAction),
            label: const Text('Add a file…'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _rootPicker(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.sm),
    child: DropdownButtonFormField<DeviceFileRoot>(
      initialValue: _root,
      decoration: const InputDecoration(
        labelText: 'Where to look',
        isDense: true,
      ),
      items: [
        for (final root in _roots)
          DropdownMenuItem(
            value: root,
            child: Text(root.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _busy != null
          ? null
          : (root) {
              if (root != null) _go(root, root.path);
            },
    ),
  );

  Widget _breadcrumb(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.sm, 0, Insets.md, Insets.sm),
    child: Row(
      children: [
        // Also a drop target, so dragging a row here moves it up a level —
        // the only way out of a folder with a drag.
        _dropTarget(
          onto: _atRoot ? null : p.posix.dirname(_path ?? ''),
          builder: (hovering) => IconButton(
            key: const Key('device-files-up'),
            tooltip: _atRoot
                ? 'Up one level'
                : 'Up one level — or drop a file here to move it up',
            isSelected: hovering,
            icon: const Icon(AppIcons.arrowUp, size: Chrome.iconAction),
            onPressed: _atRoot || _busy != null
                ? null
                : () => _go(_root!, p.posix.dirname(_path!)),
          ),
        ),
        Expanded(
          child: Text(
            _path ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: kMonoFamily,
            ),
          ),
        ),
        if (_clip case final clip?)
          Padding(
            padding: const EdgeInsets.only(left: Insets.sm),
            child: TextButton.icon(
              key: const Key('device-files-paste'),
              onPressed: _busy != null || _path == null || !_writable
                  ? null
                  : () => _paste(_path!),
              icon: const Icon(
                AppIcons.clipboardText,
                size: Chrome.iconAction,
              ),
              // The button says what it holds, so a Paste pressed ten minutes
              // later is not a guess about which file is on its way.
              label: Text('Paste — ${clip.summary}'),
            ),
          ),
      ],
    ),
  );

  bool get _writable => _root?.writable == true;

  /// Wraps [builder] in a `DragTarget` that moves a dropped entry into [onto].
  ///
  /// **`pointerDragAnchorStrategy` is on the `Draggable` side and is not
  /// optional** — see [_row]. It is named here too because this is the half
  /// that reads `DragTargetDetails`, and the two only agree about where the
  /// drop happened if the anchor is the pointer.
  ///
  /// A null [onto] accepts nothing, which is how the Up button behaves at a
  /// root: a target that accepted and then did nothing would look like a
  /// failed move.
  Widget _dropTarget({
    required String? onto,
    required Widget Function(bool hovering) builder,
  }) => DragTarget<DeviceFileEntry>(
    onWillAcceptWithDetails: (details) =>
        onto != null &&
        _busy == null &&
        _writable &&
        // Dropping something onto its own parent is a no-op the device would
        // answer with an error, so the target simply does not light up.
        p.posix.dirname(details.data.path) != onto,
    onAcceptWithDetails: (details) => _dropInto(details.data, onto!),
    builder: (context, candidate, rejected) => builder(candidate.isNotEmpty),
  );

  Widget _body(ThemeData theme, ColorScheme scheme) {
    // A refusal, first and on its own: it is not a shorter listing.
    if (_refusal case final refusal?) {
      return _notice(
        theme,
        scheme,
        icon: AppIcons.warning,
        title: 'Not permitted',
        detail: refusal,
      );
    }
    final listing = _listing;
    if (listing == null) {
      return const SizedBox.shrink();
    }
    if (listing.isEmpty && listing.skipped.isEmpty) {
      return _notice(
        theme,
        scheme,
        icon: AppIcons.folderOpen,
        title: 'Nothing here',
        detail: listing.note ?? 'This directory is empty.',
      );
    }
    final entries = [...listing.entries]
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return ListView.builder(
      itemCount: entries.length + (listing.skipped.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == entries.length) {
          return _skippedFooter(theme, scheme, listing.skipped);
        }
        return _row(theme, scheme, entries[index]);
      },
    );
  }

  /// One entry: a drag source, and a drop target when it is a directory.
  ///
  /// **`pointerDragAnchorStrategy` is load-bearing.** Flutter's default anchor
  /// makes `DragTargetDetails.offset` the *feedback widget's* top-left rather
  /// than the pointer, so with a wide row as feedback a drop lands on whatever
  /// is under the corner of the label — several rows above where the user is
  /// pointing. This cost real debugging time in the workspace splits and the
  /// same trap is here.
  Widget _row(ThemeData theme, ColorScheme scheme, DeviceFileEntry entry) {
    // The hover highlight goes on the `ListTile` itself rather than on a
    // coloured box around it: Flutter asserts on the latter, because a tile
    // paints its background and its ink on the nearest Material and anything
    // coloured in between hides both.
    Widget wrap({required bool hovering}) {
      final tile = _tile(theme, scheme, entry, hovering: hovering);
      // Only a writable root can be dragged out of: a move needs a delete at
      // the source, and a drag that always fails is worse than none.
      if (!_writable || !entry.readable || _busy != null) return tile;
      return Draggable<DeviceFileEntry>(
        data: entry,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _dragFeedback(theme, scheme, entry),
        childWhenDragging: Opacity(opacity: 0.4, child: tile),
        child: tile,
      );
    }

    if (!entry.isDirectory || !entry.readable) return wrap(hovering: false);
    return _dropTarget(
      onto: entry.path,
      builder: (hovering) => wrap(hovering: hovering),
    );
  }

  /// What follows the pointer during a drag. Deliberately small: the anchor is
  /// the pointer, and a full-width row under the cursor hides the target.
  Widget _dragFeedback(
    ThemeData theme,
    ColorScheme scheme,
    DeviceFileEntry entry,
  ) => Material(
    elevation: 4,
    color: scheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(Radii.sm),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            entry.isDirectory ? AppIcons.folder : AppIcons.note,
            size: Chrome.iconAction,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
          Text(entry.name, style: theme.textTheme.bodySmall),
        ],
      ),
    ),
  );

  Widget _tile(
    ThemeData theme,
    ColorScheme scheme,
    DeviceFileEntry entry, {
    required bool hovering,
  }) {
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return ListTile(
      dense: true,
      tileColor: hovering ? scheme.primaryContainer : null,
      leading: Icon(
        entry.isDirectory ? AppIcons.folder : AppIcons.note,
        size: Chrome.iconAction,
        // Unreadable is a fact about the entry, and it is said in the subtitle
        // as well — the dimming is not carrying the meaning on its own.
        color: entry.readable ? scheme.onSurfaceVariant : scheme.outline,
      ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle(entry), style: muted, maxLines: 1),
      onTap: _busy != null || !entry.isDirectory || !entry.readable
          ? null
          : () => _go(_root!, entry.path),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!entry.isDirectory && entry.readable)
            IconButton(
              tooltip: 'Save to this computer',
              icon: const Icon(
                AppIcons.downloadSimple,
                size: Chrome.iconAction,
              ),
              onPressed: _busy == null ? () => _pull(entry) : null,
            ),
          if (entry.readable)
            PopupMenuButton<_RowAction>(
              key: Key('device-file-menu-${entry.name}'),
              tooltip: 'More for ${entry.name}',
              icon: const Icon(
                AppIcons.dotsThreeVertical,
                size: Chrome.iconAction,
              ),
              enabled: _busy == null,
              onSelected: (action) => switch (action) {
                _RowAction.copy => _hold(entry, DeviceFileClipboardMode.copy),
                _RowAction.cut => _hold(entry, DeviceFileClipboardMode.cut),
                _RowAction.copyForHost => unawaited(_copyForHost(entry)),
              },
              itemBuilder: (context) => [
                // Copy and Cut hold a *device path* and are pasted by the
                // device — no host round trip, which is the point.
                if (_writable)
                  const PopupMenuItem(
                    value: _RowAction.copy,
                    child: Text('Copy on the device'),
                  ),
                if (_writable)
                  const PopupMenuItem(
                    value: _RowAction.cut,
                    child: Text('Cut on the device'),
                  ),
                if (!entry.isDirectory)
                  const PopupMenuItem(
                    value: _RowAction.copyForHost,
                    child: Text('Copy for this computer'),
                  ),
              ],
            ),
          if (_writable)
            IconButton(
              tooltip: 'Delete on the device',
              icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
              onPressed: _busy == null ? () => _delete(entry) : null,
            ),
        ],
      ),
    );
  }

  String _subtitle(DeviceFileEntry entry) {
    final parts = <String>[
      if (!entry.readable) 'not permitted',
      if (entry.linkTarget case final target?) '→ $target',
      if (entry.sizeBytes case final bytes?) _bytes(bytes),
      ?entry.modifiedLabel,
      ?entry.mode,
    ];
    return parts.isEmpty ? entry.kind.name : parts.join(' · ');
  }

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Lines the parser could not read, said out loud.
  ///
  /// `ls -l` output differs by device and by Android version, and a line this
  /// build cannot parse is a **known unknown** — dropping it silently would
  /// make a directory look shorter than it is.
  Widget _skippedFooter(
    ThemeData theme,
    ColorScheme scheme,
    List<SkippedDeviceEntry> skipped,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 0),
    child: Text(
      skipped.length == 1
          ? '1 more line could not be read: ${skipped.single.reason}'
          : '${skipped.length} more lines could not be read',
      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    ),
  );

  Widget _notice(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String detail,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Insets.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: scheme.onSurfaceVariant),
          const SizedBox(height: Insets.sm),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: Insets.xs),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

/// The row menu's items. An enum so the switch is exhaustive: an action added
/// without a handler is a compile error rather than a menu entry that does
/// nothing.
enum _RowAction { copy, cut, copyForHost }

