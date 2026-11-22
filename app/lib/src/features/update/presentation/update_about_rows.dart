import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_row.dart';
import '../application/github_update_controller.dart';
import '../domain/install_kind.dart';
import '../domain/update_status.dart';
import 'update_actions.dart';

/// Settings › About's update rows: where an update stands, Check for updates,
/// and the switch for checking on its own. Nothing where GitHub is not this
/// install's update source (Play, iOS, the web).
class UpdateAboutRows extends ConsumerWidget {
  const UpdateAboutRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(githubUpdateProvider);
    final kind = state.kind;
    if (kind == null || !kind.usesGitHub) return const SizedBox.shrink();
    final automatic = ref.watch(
      settingsControllerProvider.select((s) => s.checkForUpdates),
    );
    final controller = ref.read(githubUpdateProvider.notifier);
    final status = state.status;
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: status is UpdateFailed
          ? theme.colorScheme.error
          : theme.colorScheme.onSurfaceVariant,
    );

    final Widget control = switch (status) {
      UpdateAvailable(:final plan) => FilledButton.icon(
        key: const ValueKey('about_update_now'),
        icon: const Icon(AppIcons.downloadSimple),
        label: Text(updateActionLabel(plan)),
        onPressed: () => unawaited(controller.update()),
      ),
      final UpdateReady ready => FilledButton(
        key: const ValueKey('about_update_install'),
        onPressed: () => unawaited(finishUpdate(context, ref, ready)),
        child: Text(readyActionLabel(ready)),
      ),
      _ => OutlinedButton.icon(
        key: const ValueKey('about_check_updates'),
        icon: const Icon(AppIcons.arrowsClockwise),
        label: const Text('Check for updates'),
        onPressed: status is UpdateChecking || status is UpdateDownloading
            ? null
            : () => unawaited(controller.check(manual: true)),
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          key: const ValueKey('about_updates_row'),
          label: 'Updates',
          helpWidget: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                updateStatusText(status, kind),
                key: const ValueKey('about_update_status'),
                style: quiet,
              ),
              if (status is UpdateDownloading) ...[
                const SizedBox(height: Insets.xs),
                LinearProgressIndicator(value: status.fraction),
              ],
            ],
          ),
          control: control,
        ),
        SettingsSwitchRow(
          key: const ValueKey('about_check_automatically'),
          label: 'Check for updates automatically',
          help: 'Shortly after launch and every six hours, from GitHub.',
          value: automatic,
          onChanged: ref
              .read(settingsControllerProvider.notifier)
              .setCheckForUpdates,
        ),
      ],
    );
  }
}

/// One line for where an update stands.
String updateStatusText(
  UpdateStatus status,
  InstallKind kind,
) => switch (status) {
  UpdateIdle() => 'Not checked since Karmashala started.',
  UpdateChecking() => 'Checking…',
  UpdateUpToDate() => 'Karmashala is up to date.',
  UpdateAvailable(:final release) => switch (kind) {
    InstallKind.windowsPortable || InstallKind.linuxTarball =>
      'Karmashala ${release.versionText} is available. This copy updates '
          'by hand: download it from the release page.',
    _ => 'Karmashala ${release.versionText} is available.',
  },
  final UpdateDownloading downloading =>
    'Downloading Karmashala ${downloading.release.versionText}'
        '${downloading.fraction == null ? '…' : ' · ${(downloading.fraction! * 100).round()}%'}',
  final UpdateReady ready => '${readyText(ready)}.',
  UpdateHandedOff(:final message) => message,
  UpdateFailed(:final message) => message,
};
