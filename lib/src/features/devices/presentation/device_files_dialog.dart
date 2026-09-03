import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/device_fleet.dart';
import '../domain/android_device.dart';
import '../domain/device_driver.dart';
import '../domain/device_files.dart';
import '../domain/device_target.dart';

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
class DeviceFilesDialog extends ConsumerStatefulWidget {
  const DeviceFilesDialog({required this.device, super.key});

  final AndroidDevice device;

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
    final directory = await getDirectoryPath(
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
    final file = await openFile();
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
        if (_root?.writable == true && _path != null)
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
        IconButton(
          tooltip: 'Up one level',
          icon: const Icon(AppIcons.arrowUp, size: Chrome.iconAction),
          onPressed: _atRoot || _busy != null
              ? null
              : () => _go(_root!, p.posix.dirname(_path!)),
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
      ],
    ),
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

  Widget _row(ThemeData theme, ColorScheme scheme, DeviceFileEntry entry) {
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return ListTile(
      dense: true,
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
          if (_root?.writable == true)
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
