import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart' show CommandException;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import '../application/device_fleet.dart';
import '../data/host_clipboard.dart';

/// Browsing a device's storage, and moving files across — in the app's one
/// file browser ([FileBrowserView]), with the device over adb as its source:
/// the roots the driver says it can reach are its shortcuts, never a
/// filesystem, and a refusal is never "empty". Folders pinned here are the
/// device's (`device:<serial>`), so a pinned `/sdcard/Download` on one phone
/// stays that phone's.
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

  /// Creates the staging directory. A seam like [host] is one: a widget test
  /// runs inside `FakeAsync`, where a real `Directory.create` never completes.
  final HostDirectoryMaker makeDirectory;

  static Future<void> show(BuildContext context, AndroidDevice device) =>
      showDialog<void>(
        context: context,
        builder: (_) => DeviceFilesDialog(device: device),
      );

  /// The environment a device's paths — and its pins — are keyed by.
  static String environmentIdOf(AndroidDevice device) =>
      'device:${device.serial}';

  @override
  ConsumerState<DeviceFilesDialog> createState() => _DeviceFilesDialogState();
}

class _DeviceFilesDialogState extends ConsumerState<DeviceFilesDialog> {
  DeviceDriver? _driver;
  List<DeviceFileRoot> _roots = const [];
  FileBrowserController? _browser;

  /// What the device said of each folder it listed, by path: the entries the
  /// actions need, and the rows and notes the browser has no words for.
  final Map<String, DeviceDirectoryListing> _listings = {};

  /// A refusal before there was anything to browse.
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

  @override
  void dispose() {
    _browser?.removeListener(_redraw);
    _browser?.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
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
      final browser = FileBrowserController(
        sources: [_sourceFor(driver, roots)],
        environmentId: DeviceFilesDialog.environmentIdOf(widget.device),
        startAt: roots.first.path,
      )..addListener(_redraw);
      setState(() {
        _busy = null;
        _browser = browser;
      });
      await browser.start();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _refusal = _worded(error);
      });
    }
  }

  BrowseSource _sourceFor(DeviceDriver driver, List<DeviceFileRoot> roots) =>
      BrowseSource(
        id: DeviceFilesDialog.environmentIdOf(widget.device),
        label: widget.device.displayName,
        home: () async => roots.first.path,
        lister: (path) async {
          final DeviceDirectoryListing listing;
          try {
            listing = await driver.listDirectory(path);
          } on Object catch (error) {
            // Worded in the device's terms; the browser shows it in place of
            // the rows, never as an empty folder.
            throw StateError(_worded(error));
          }
          _listings[path] = listing;
          return [
            for (final entry in listing.entries)
              BrowsedEntry(
                name: entry.name,
                path: entry.path,
                isDirectory: entry.isDirectory,
                hidden: entry.isHidden,
                isLink: entry.kind == DeviceEntryKind.symlink,
                sizeBytes: entry.sizeBytes,
                readable: entry.readable,
              ),
          ];
        },
        places: () async => [
          for (final root in roots)
            BrowsePlace(
              root.label,
              root.path,
              root.writable ? AppIcons.folderOpen : AppIcons.stack,
            ),
        ],
        createDirectory: (directory, name) async {
          final path = devicePathIn(directory, name);
          try {
            await driver.makeDirectory(path).timeout(transferTimeout);
          } on Object catch (error) {
            throw StateError(_worded(error));
          }
          return path;
        },
      );

  /// How long one copy may take before the dialog stops waiting on it. The
  /// adb process is not killed; the dialog just becomes usable again.
  static const Duration transferTimeout = Duration(minutes: 10);

  /// A refusal is already worded; anything else is said in the device's terms
  /// too, because `_busy` is cleared in the same breath and must never wedge.
  static String _worded(Object error) => switch (error) {
    DeviceRefusal() => error.toString(),
    CommandException(:final message) => 'adb could not be run: $message',
    TimeoutException() =>
      'Gave up after ${transferTimeout.inMinutes} minutes; adb may still be '
          'copying.',
    _ => '$error',
  };

  String? get _path => _browser?.directory;

  /// The root the open folder is under — the longest one that holds it — and
  /// so whether a push, a paste or a delete has a chance there.
  DeviceFileRoot? get _root {
    final path = _path;
    if (path == null) return null;
    DeviceFileRoot? best;
    for (final root in _roots) {
      final base = root.path.endsWith('/') ? root.path : '${root.path}/';
      if (path == root.path || '$path/' == base || path.startsWith(base)) {
        if (best == null || root.path.length > best.path.length) best = root;
      }
    }
    return best;
  }

  bool get _writable => _root?.writable == true;

  /// The device's own entry behind a browsed row.
  DeviceFileEntry? _entryOf(BrowsedEntry row) {
    for (final listing in _listings.values) {
      for (final entry in listing.entries) {
        if (entry.path == row.path) return entry;
      }
    }
    return null;
  }

  Future<void> _refresh() async => _browser?.relist();

  Future<void> _pull(DeviceFileEntry entry) async {
    final driver = _driver;
    if (driver == null) return;
    // A directory to save into, not a save dialog: `file_selector`'s save
    // sheet is the one piece of this not dependable on every desktop.
    // adb runs on this device, so the copy lands in this device's folders.
    final directory = await pickDeviceDirectory(
      context: context,
      // Nothing here knows a folder on this computer worth suggesting; the
      // fallback chain picks one that exists rather than the shell's own MRU.
      startNear: null,
      what: 'where to save ${entry.name}',
      confirmButtonText: 'Save here',
    );
    if (directory == null || !mounted) return;
    setState(() => _busy = 'Copying ${entry.name} to this computer…');
    try {
      final moved = await driver
          .pullFile(
            devicePath: entry.path,
            hostPath: p.join(directory, entry.name),
          )
          .timeout(transferTimeout);
      if (!mounted) return;
      setState(() => _busy = null);
      _say(
        'Saved to ${moved.hostPath}${moved.note == null ? '' : ' · ${moved.note}'}',
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = null);
      _say(_worded(error));
    }
  }

  Future<void> _push() async {
    final driver = _driver;
    final path = _path;
    if (driver == null || path == null) return;
    final file = await pickDeviceFile(
      context: context,
      startNear: null,
      what: 'a file to copy to the device',
    );
    if (file == null || !mounted) return;
    setState(() => _busy = 'Copying ${file.name} to the device…');
    try {
      final moved = await driver
          .pushFile(
            hostPath: file.path,
            devicePath: p.posix.join(path, file.name),
          )
          .timeout(transferTimeout);
      if (!mounted) return;
      setState(() => _busy = null);
      _say(moved.note ?? 'Copied to ${moved.devicePath}');
      await _refresh();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = null);
      // The refusal a push is *meant* to give: an existing file, not replaced.
      _say(_worded(error));
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
    final report = await _guarded(
      () => pasteOnDevice(driver: driver, clip: clip, directory: directory),
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

  /// The action helpers word a refusal themselves; this words everything else,
  /// so an adb that cannot run clears `_busy` like any other outcome.
  Future<DeviceFileActionReport> _guarded(
    Future<DeviceFileActionReport> Function() action,
  ) async {
    try {
      return await action().timeout(transferTimeout);
    } on Object catch (error) {
      return DeviceFileActionReport(_worded(error));
    }
  }

  /// Copies [entry] off the device and onto **this computer's** clipboard, so
  /// it can be pasted into Explorer or Finder.
  Future<void> _copyForHost(DeviceFileEntry entry) async {
    final driver = _driver;
    if (driver == null) return;
    setState(() => _busy = 'Copying ${entry.name} to this computer…');
    final report = await _guarded(
      () => copyToHostClipboard(
        driver: driver,
        host: widget.host,
        temporaryDirectory: _temporaryDirectory,
        entries: [entry],
        makeDirectory: widget.makeDirectory,
      ),
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
    final report = await _guarded(
      () => pasteFromHostClipboard(
        driver: driver,
        host: widget.host,
        directory: path,
      ),
    );
    if (!mounted) return;
    setState(() => _busy = null);
    _say(report.message);
    if (report.deviceChanged) await _refresh();
  }

  /// Drops [entry] into [directory] — the drag gesture for a device-side move.
  /// A move, not a copy, and it leaves the app's own clipboard alone.
  Future<void> _dropInto(DeviceFileEntry entry, String directory) async {
    final driver = _driver;
    if (driver == null) return;
    final clip = DeviceFileClipboard(
      serial: widget.device.serial,
      entries: [entry],
      mode: DeviceFileClipboardMode.cut,
    );
    setState(() => _busy = 'Moving ${entry.name} into $directory…');
    final report = await _guarded(
      () => pasteOnDevice(driver: driver, clip: clip, directory: directory),
    );
    if (!mounted) return;
    setState(() => _busy = null);
    _say(report.message);
    if (report.deviceChanged) await _refresh();
  }

  /// Deleting, which nothing on the far side can undo.
  Future<void> _delete(DeviceFileEntry entry) async {
    final driver = _driver;
    if (driver == null) return;
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
      await _refresh();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = null);
      _say(_worded(error));
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// The body's height where the window allows it.
  static const bodyHeight = 520.0;

  @override
  Widget build(BuildContext context) {
    final browser = _browser;
    return AlertDialog(
      title: Text('Files on ${widget.device.displayName}'),
      contentPadding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.sm,
        Insets.md,
        0,
      ),
      // Not `BoundedDialogContent`: the listing is a lazy ListView in an
      // Expanded, which a body that scrolls as a whole cannot hold. The height
      // is a ceiling — a shorter window shrinks the listing, not the dialog.
      content: SizedBox(
        width: DialogWidth.wide,
        height: bodyHeight,
        child: browser == null
            ? _before(context)
            : FileBrowserView(
                controller: browser,
                offerNewFolder: _writable,
                offerNewFile: false,
                openFileIcon: AppIcons.downloadSimple,
                openFileTooltip: 'Save to this computer',
                canOpenFile: (row) => _busy == null && row.readable,
                onOpenFile: (row) {
                  final entry = _entryOf(row);
                  if (entry != null) unawaited(_pull(entry));
                },
                subtitleOf: (row) {
                  final entry = _entryOf(row);
                  return entry == null ? null : _subtitle(entry);
                },
                rowActions: _rowActions,
                rowWrapper: _draggable,
                upWrapper: (up) => _dropTarget(
                  onto: browser.canGoUp
                      ? p.posix.dirname(browser.directory)
                      : null,
                  builder: (hovering) => Tooltip(
                    message: 'Drop a file here to move it up',
                    child: Material(
                      key: const Key('device-files-up'),
                      color: hovering
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Colors.transparent,
                      shape: const CircleBorder(),
                      child: up,
                    ),
                  ),
                ),
                actions: _toolbar,
                footer: _footer,
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// Before the device has said what it can reach: progress, or its refusal.
  Widget _before(BuildContext context) {
    if (_refusal case final refusal?) {
      return PanePlaceholder(
        icon: AppIcons.warning,
        message: 'Not permitted\n$refusal',
      );
    }
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const InlineSpinner(),
          const SizedBox(width: Insets.sm),
          Text(_busy ?? '', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  /// Paste while something is held, and the two ways in from this computer.
  Widget _toolbar(BuildContext context) {
    final held = _clip;
    final path = _path;
    final idle = _busy == null && path != null;
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        if (_writable && path != null)
          TextButton.icon(
            onPressed: idle ? _push : null,
            icon: const Icon(AppIcons.uploadSimple, size: Chrome.iconSmall),
            label: const Text('Add a file…'),
          ),
        if (_writable && path != null)
          TextButton.icon(
            key: const Key('device-files-paste-from-host'),
            onPressed: idle ? _pasteFromHost : null,
            icon: const Icon(AppIcons.clipboardText, size: Chrome.iconSmall),
            label: const Text('Paste from this computer'),
          ),
        if (held != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: TextButton.icon(
              key: const Key('device-files-paste'),
              onPressed: idle && _writable ? () => _paste(path) : null,
              icon: const Icon(AppIcons.clipboardText, size: Chrome.iconSmall),
              // The button says what it holds, so a Paste pressed ten minutes
              // later is not a guess about which file is on its way — and its
              // tooltip says it whole when it is cut short.
              label: Tooltip(
                message: 'Paste — ${held.summary}',
                excludeFromSemantics: true,
                child: Text(
                  'Paste — ${held.summary}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<FileBrowserRowAction> _rowActions(BrowsedEntry row) {
    final entry = _entryOf(row);
    if (entry == null || !entry.readable || _busy != null) return const [];
    return [
      // Copy and Cut hold a *device path* and are pasted by the device — no
      // host round trip, which is the point.
      if (_writable)
        FileBrowserRowAction(
          label: 'Copy on the device',
          icon: AppIcons.copySimple,
          onSelected: (_) => _hold(entry, DeviceFileClipboardMode.copy),
        ),
      if (_writable)
        FileBrowserRowAction(
          label: 'Cut on the device',
          icon: AppIcons.arrowBendDownRight,
          onSelected: (_) => _hold(entry, DeviceFileClipboardMode.cut),
        ),
      if (!entry.isDirectory)
        FileBrowserRowAction(
          label: 'Copy for this computer',
          icon: AppIcons.clipboardText,
          onSelected: (_) => unawaited(_copyForHost(entry)),
        ),
      if (_writable)
        FileBrowserRowAction(
          label: 'Delete on the device',
          icon: AppIcons.trash,
          destructive: true,
          onSelected: (_) => unawaited(_delete(entry)),
        ),
    ];
  }

  /// One row: a drag source, and a drop target when it is a directory. With
  /// no `pointerDragAnchorStrategy` a drop lands under the feedback's corner.
  Widget _draggable(BrowsedEntry row, Widget tile) {
    final entry = _entryOf(row);
    if (entry == null) return tile;
    Widget wrap({required bool hovering}) {
      // A Material, not a coloured box, behind the highlight: a tile's ink
      // paints on the nearest Material.
      final lit = Material(
        color: hovering
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        child: tile,
      );
      // Only a writable root can be dragged out of: a move needs a delete at
      // the source, and a drag that always fails is worse than none.
      if (!_writable || !entry.readable || _busy != null) return lit;
      return Draggable<DeviceFileEntry>(
        data: entry,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _dragFeedback(entry),
        childWhenDragging: Opacity(opacity: 0.4, child: lit),
        child: lit,
      );
    }

    if (!entry.isDirectory || !entry.readable) return wrap(hovering: false);
    return _dropTarget(
      onto: entry.path,
      builder: (hovering) => wrap(hovering: hovering),
    );
  }

  /// Wraps [builder] in a `DragTarget` that moves a dropped entry into [onto].
  /// A null [onto] accepts nothing: one that did nothing would look failed.
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

  /// What follows the pointer during a drag. Deliberately small: the anchor is
  /// the pointer, and a full-width row under the cursor hides the target.
  Widget _dragFeedback(DeviceFileEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
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
              entry.isDirectory ? AppIcons.folder : AppIcons.file,
              size: Chrome.iconAction,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            Text(entry.name, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  /// Under the browser: what is under way, then what the device said of this
  /// folder that is not a row — why it is empty, and lines `ls` printed that
  /// could not be read, said out loud because dropping one silently makes a
  /// directory look shorter than it is.
  Widget _footer(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final listing = _path == null ? null : _listings[_path];
    final skipped = listing?.skipped ?? const <SkippedDeviceEntry>[];
    final note = listing != null && listing.isEmpty ? listing.note : null;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy case final busy?)
            Row(
              children: [
                const InlineSpinner(),
                const SizedBox(width: Insets.sm),
                Expanded(child: Text(busy, style: theme.textTheme.bodySmall)),
              ],
            ),
          if (note != null) Text(note, style: muted),
          if (skipped.isNotEmpty)
            Text(
              skipped.length == 1
                  ? '1 more line could not be read: ${skipped.single.reason}'
                  : '${skipped.length} more lines could not be read',
              style: muted,
            ),
        ],
      ),
    );
  }

  String _subtitle(DeviceFileEntry entry) {
    final parts = <String>[
      if (!entry.readable) 'not permitted',
      if (entry.linkTarget case final target?) '→ $target',
      if (entry.sizeBytes case final bytes?) describeBrowsedSize(bytes),
      ?entry.modifiedLabel,
      ?entry.mode,
    ];
    return parts.isEmpty ? entry.kind.name : parts.join(' · ');
  }
}
