import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';

import '../application/artifact_actions.dart';
import 'html_preview.dart';

/// The tallest an HTML artifact grows inside a thread card before it scrolls
/// inside itself.
const double kInlineHtmlMaxHeight = 264;

/// An HTML artifact, drawn by [htmlEngineProvider]'s engine — natively, with
/// no script run — with its source a toggle away and the browser, where its
/// scripts run inside the sandbox shell, one tap away.
class ArtifactHtmlView extends ConsumerWidget {
  const ArtifactHtmlView({
    required this.artifact,
    required this.revision,
    required this.html,
    this.compact = false,
    super.key,
  });

  final Artifact artifact;
  final int revision;
  final String html;

  /// Inside a thread card: grows to [kInlineHtmlMaxHeight], then scrolls.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(artifactActionsProvider);
    return HtmlPreview(
      html: html,
      allowNetwork: artifact.networkAllowed,
      maxHeight: compact ? kInlineHtmlMaxHeight : null,
      onOpenInBrowser: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        String said;
        try {
          said = await actions.openInBrowser(artifact, revision);
        } on Object catch (error) {
          said = 'That did not work: $error';
        }
        messenger?.showSnackBar(SnackBar(content: Text(said)));
      },
    );
  }
}

/// The bytes of an HTML artifact as text.
String artifactHtmlText(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);
