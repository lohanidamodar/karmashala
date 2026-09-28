import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/failure_words.dart';
import '../../files/data/files_client.dart';
import '../application/dropped_paths.dart';
import '../application/local_host_providers.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;
import '../application/terminal_profiles.dart';
import '../application/terminal_sessions_controller.dart';

/// Files dragged in from the OS onto a pane: their paths are pasted at its
/// prompt, spelled for the side the pane runs on, as a native terminal does.
/// An agent CLI reads a pasted image path as the image. When the server is
/// on another machine (slice 5e) the files are uploaded to it first and its
/// paths pasted.
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
  bool _over = false;

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
      windowsHost: Platform.isWindows,
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
    final access = ref.read(serverAccessProvider);
    final link = access == null ? null : SharedHostLinks.current(access);
    final text = droppedPathsText(
      landed,
      reach: PaneReach.local,
      windowsHost: link?.welcome.operatingSystem == 'windows',
    );
    if (text == null || !mounted) return;
    instance.terminal.paste(text);
    instance.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (details) {
        setState(() => _over = false);
        final paths = [for (final file in details.files) file.path];
        if (ref.read(dataClientProvider).serverOnThisMachine) {
          _drop(paths);
        } else {
          unawaited(_upload(paths));
        }
      },
      // The Files panel's rows drag inside the app, which no OS drop sees.
      child: DragTarget<HostPathDrag>(
        onAcceptWithDetails: (details) => _drop(details.data.paths),
        builder: (context, candidates, _) =>
            _overlaid(theme, over: _over || candidates.isNotEmpty),
      ),
    );
  }

  Widget _overlaid(ThemeData theme, {required bool over}) => Stack(
    children: [
      Positioned.fill(child: widget.child),
      if (over)
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: StateLayers.dropTarget(theme.colorScheme),
                border: Border.all(color: theme.colorScheme.primary, width: 2),
              ),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm,
                    vertical: Insets.xs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        AppIcons.file,
                        size: Chrome.iconSmall,
                        color: theme.colorScheme.onPrimary,
                      ),
                      const SizedBox(width: Insets.xs),
                      Text(
                        'Drop to paste the path',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
