import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:agent_cli/process.dart';
import '../application/ssh_failure.dart';
import '../application/ssh_providers.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:karmashala_ssh/connection.dart';
import 'host_key_changed_alert.dart';

/// Browses a host's filesystem over SFTP. Every path it produces is an
/// [EnvironmentPath] in `ssh:<hostId>`, never one something would open here.
class RemoteFileBrowserDialog extends ConsumerStatefulWidget {
  const RemoteFileBrowserDialog({
    required this.host,
    this.selectFolder = false,
    super.key,
  });

  final SshHost host;
  final bool selectFolder;

  static Future<String?> pickDirectory(
    BuildContext context, {
    required SshHost host,
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => RemoteFileBrowserDialog(host: host, selectFolder: true),
      );

  static Future<void> show(BuildContext context, {required SshHost host}) =>
      showDialog<void>(
        context: context,
        builder: (_) => RemoteFileBrowserDialog(host: host),
      );

  @override
  ConsumerState<RemoteFileBrowserDialog> createState() =>
      _RemoteFileBrowserDialogState();
}

class _RemoteFileBrowserDialogState
    extends ConsumerState<RemoteFileBrowserDialog> {
  RemoteFileBrowser? _browser;
  EnvironmentPath? _directory;
  List<RemoteDirectoryEntry> _entries = const [];
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    // Releases the SFTP channel; the pooled SSH connection itself stays up for
    // whatever else is using it.
    _browser?.close();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final browser = RemoteFileBrowser(
        connection: ref
            .read(sshConnectionPoolProvider)
            .forHostId(widget.host.id),
        environmentId: widget.host.environmentId,
      );
      _browser = browser;
      final start = widget.host.defaultDirectory ?? await browser.home();
      await _listDirectory(start);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  Future<void> _listDirectory(EnvironmentPath directory) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final entries = await _browser!.list(directory);
      if (!mounted) return;
      setState(() {
        _directory = directory;
        _entries = entries;
        _busy = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final directory = _directory;
    final parent = directory == null ? null : parentRemotePath(directory.path);
    final error = _error;
    final rejection = hostKeyRejectionIn(error);
    // One answer for every browser in the app, so this folder does not read
    // one way here and another in the picker.
    final visible = HiddenFilesPreference.shown
        ? _entries
        : [
            for (final entry in _entries)
              if (!entry.isHidden) entry,
          ];
    final hiddenCount = _entries.where((entry) => entry.isHidden).length;

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.folderOpen,
        title: widget.host.name,
        subtitle: 'Files on ${widget.host.address}, over SFTP.',
      ),
      content: SizedBox(
        width: 620,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Up one level',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.arrowUp),
                  onPressed: parent == null || _busy
                      ? null
                      : () => _listDirectory(
                          EnvironmentPath(
                            environmentId: widget.host.environmentId,
                            path: parent,
                          ),
                        ),
                ),
                Expanded(
                  child: SelectableText(
                    directory?.path ?? '…',
                    maxLines: 1,
                    style: MonoStyles.body,
                  ),
                ),
                HiddenFilesChip(
                  hiddenCount: hiddenCount,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(width: Insets.xs),
                IconButton(
                  tooltip: 'Refresh',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.arrowsClockwise),
                  onPressed: directory == null || _busy
                      ? null
                      : () => _listDirectory(directory),
                ),
              ],
            ),
            const Divider(height: Insets.lg),
            if (rejection != null)
              HostKeyChangedAlert(presentation: rejection.presentation)
            else if (error != null)
              DesktopErrorBanner(describeSshFailure(error)),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(Insets.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error == null)
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          'Nothing here.',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (_, index) {
                          final entry = visible[index];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              entry.isDirectory
                                  ? AppIcons.folder
                                  : AppIcons.article,
                            ),
                            title: Text(
                              entry.name,
                              style: MonoStyles.body,
                            ),
                            subtitle: entry.isDirectory
                                ? null
                                : Text(_describeSize(entry.sizeBytes)),
                            onTap: entry.isDirectory
                                ? () => _listDirectory(entry.path)
                                : null,
                          );
                        },
                      ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.selectFolder ? 'Cancel' : 'Close'),
        ),
        if (widget.selectFolder)
          FilledButton(
            onPressed: _directory == null || _busy
                ? null
                : () => Navigator.of(context).pop(_directory!.path),
            child: const Text('Select folder'),
          ),
      ],
    );
  }

  static String _describeSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
