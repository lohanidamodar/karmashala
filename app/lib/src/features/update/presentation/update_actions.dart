import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../git/application/remote_links.dart' show openExternalUrlProvider;
import '../application/github_update_controller.dart';
import '../domain/github_release.dart';
import '../domain/install_kind.dart';
import '../domain/update_status.dart';

/// The release body, as markdown, in a sheet on a phone and a dialog on a
/// desktop.
Future<void> showReleaseNotes(
  BuildContext context,
  WidgetRef ref,
  GitHubRelease release,
) => showAdaptiveModal<void>(
  context: context,
  title: "What's new in Karmashala ${release.versionText}",
  width: DialogWidth.regular,
  builder: (context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
    child: MarkdownMessage(
      release.notes.trim().isEmpty
          ? 'This release has no notes.'
          : release.notes,
      selectable: false,
      onLinkTap: (href) => ref.read(openExternalUrlProvider)(href),
    ),
  ),
);

/// The words on the button that finishes a [UpdateReady].
String readyActionLabel(UpdateReady ready) =>
    ready.plan.method == UpdateMethod.runInstaller
    ? 'Install and restart'
    : 'Restart';

/// What [UpdateReady] says it is waiting for.
String readyText(UpdateReady ready) =>
    ready.plan.method == UpdateMethod.runInstaller
    ? 'Karmashala ${ready.release.versionText} is ready to install'
    : 'Karmashala ${ready.release.versionText} is in place — restart to use it';

/// Installs a downloaded update. The installer closes the app, so it asks
/// first; an AppImage already swapped in only needs the restart.
Future<void> finishUpdate(
  BuildContext context,
  WidgetRef ref,
  UpdateReady ready,
) async {
  if (ready.plan.method == UpdateMethod.runInstaller) {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Update Karmashala?',
      message:
          'Karmashala will close to update and opens again when the '
          'installer finishes. Sessions the session host is running carry on.',
      confirmLabel: 'Update and restart',
    );
    if (!confirmed) return;
  }
  unawaited(ref.read(githubUpdateProvider.notifier).install());
}

/// The label Update wears for [plan]: it says where it goes when it only
/// opens something.
String updateActionLabel(UpdatePlan plan) => switch (plan.method) {
  UpdateMethod.openReleasePage => 'Open release page',
  UpdateMethod.openApk => 'Download',
  _ => 'Update',
};
