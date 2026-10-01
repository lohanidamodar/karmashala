import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_runtime/instances.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/file_drop/file_drop_router.dart';
import '../../../core/util/failure_words.dart';
import '../../files/data/files_client.dart';
import '../application/dropped_paths.dart';
import '../application/terminal_profiles.dart';
import '../application/terminal_sessions_controller.dart';

/// Files dragged in from the OS onto a pane: their paths are pasted at its
/// prompt, spelled for the side the pane runs on, as a native terminal does.
/// An agent CLI reads a pasted image path as the image. When the server is
/// on another machine (slice 5e) the files are uploaded to it first and its
/// paths pasted. A [FileDropZone]: the app's [FileDropRouter] hears the OS.
class TerminalFileDrop extends ConsumerStatefulWidget {
  const TerminalFileDrop({
    required this.paneId,
    required this.child,
    super.key,
  });

  final String paneId;
  final Widget child;

  @override
  ConsumerState<TerminalFileDrop> createState() => _TerminalFileDropState();
}

class _TerminalFileDropState extends ConsumerState<TerminalFileDrop> {
  TerminalInstance? get _instance => ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(widget.paneId);

  PaneReach _reachOf(TerminalInstance instance) {
    final launch = instance.agentLaunch;
    if (launch != null) {
      if (launch.sshHostId != null) return PaneReach.ssh;
      if (launch.wslDistribution != null) return PaneReach.wsl;
      return PaneReach.local;
    }
    for (final profile in ref.read(terminalProfilesProvider)) {
      if (profile.id != instance.profileId) continue;
      if (profile.sshHostId != null) return PaneReach.ssh;
      if (profile.wslDistribution != null) return PaneReach.wsl;
    }
    return PaneReach.local;
  }

  void _drop(List<String> paths) {
    final instance = _instance;
    if (instance == null) return;
    final text = droppedPathsText(
      paths,
      reach: _reachOf(instance),
      windowsHost: ref.read(capabilitiesProvider).serverOnWindows,
    );
    if (text == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'This pane runs where those files are not, so nothing was pasted.',
          ),
        ),
      );
      return;
    }
    instance.terminal.paste(text);
    instance.focusNode.requestFocus();
  }

  /// This machine's files onto a server elsewhere: each is uploaded to its
  /// uploads folder, and the paths it landed at are pasted.
  Future<void> _upload(List<String> paths) async {
    final instance = _instance;
    if (instance == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final files = ref.read(filesClientProvider);
    final landed = <String>[];
    try {
      for (final path in paths) {
        final file = File(path);
        if (!file.existsSync()) continue;
        landed.add(
          (await files.upload(
            file.uri.pathSegments.last,
            await file.length(),
            file.openRead(),
          )).path,
        );
      }
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Could not send the file to the server: '
            '${describeFailure(error)}',
          ),
        ),
      );
      return;
    }
    final text = droppedPathsText(
      landed,
      reach: PaneReach.local,
      windowsHost: ref.read(capabilitiesProvider).serverOnWindows,
    );
    if (text == null || !mounted) return;
    instance.terminal.paste(text);
    instance.focusNode.requestFocus();
  }

  void _dropFromOs(List<String> paths) {
    if (ref.read(capabilitiesProvider).readsServerDisk) {
      _drop(paths);
    } else {
      unawaited(_upload(paths));
    }
  }

  @override
  Widget build(BuildContext context) => FileDropZone(
    name: 'terminal pane ${widget.paneId}',
    onFiles: _dropFromOs,
    // The Files panel's rows drag inside the app, which no OS drop sees.
    builder: (context, hovering) => DragTarget<HostPathDrag>(
      onAcceptWithDetails: (details) => _drop(details.data.paths),
      builder: (context, candidates, _) => FileDropHighlight(
        label: 'Drop to paste the path',
        visible: hovering || candidates.isNotEmpty,
        child: widget.child,
      ),
    ),
  );
}
