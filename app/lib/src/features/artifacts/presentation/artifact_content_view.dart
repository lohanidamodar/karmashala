import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_ui/diagrams.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../application/artifact_providers.dart';
import '../application/artifact_web_view_support.dart';
import '../domain/artifact_fallback.dart';
import 'artifact_fallback_view.dart';
import 'artifact_web_view.dart';

/// One revision of an artifact, drawn the way its kind is: HTML in the
/// sandboxed web view, everything else natively with no script at all.
/// Whatever cannot be drawn here says why and offers what still works.
class ArtifactContentView extends ConsumerWidget {
  const ArtifactContentView({
    required this.artifact,
    required this.revision,
    this.compact = false,
    super.key,
  });

  final Artifact artifact;
  final int revision;

  /// Inside a thread card: no web view, and the height is the card's.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (artifact.kind == ArtifactKind.html && compact) {
      return const SizedBox.shrink();
    }
    String? webViewProblem;
    if (artifact.kind == ArtifactKind.html) {
      final support = ref.watch(artifactWebViewSupportProvider);
      if (support.isLoading) return const _Loading();
      webViewProblem = support.value;
    }
    final fallback = artifactRenderFallback(
      artifact,
      webViewProblem: webViewProblem,
    );
    if (fallback != null) {
      return ArtifactFallbackView(
        artifact: artifact,
        revision: revision,
        fallback: fallback,
      );
    }
    final content = ref.watch(
      artifactContentProvider((id: artifact.id, revision: revision)),
    );
    return content.when(
      loading: () => const _Loading(),
      error: (error, _) => ArtifactFallbackView(
        artifact: artifact,
        revision: revision,
        fallback: artifactLoadFallback(error),
      ),
      data: (bytes) => _drawn(context, ref, bytes),
    );
  }

  Widget _drawn(BuildContext context, WidgetRef ref, Uint8List bytes) {
    String text() => utf8.decode(bytes, allowMalformed: true);
    final drawn = switch (artifact.kind) {
      ArtifactKind.html => ref.watch(artifactWebSurfaceProvider)(
        context,
        ArtifactWebDocument(
          shell: artifactSandboxShell(
            text(),
            allowNetwork: artifact.networkAllowed,
          ),
          allowNetwork: artifact.networkAllowed,
        ),
      ),
      ArtifactKind.svg => SvgPicture.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: (context, error, _) => _Unreadable(
          'This SVG could not be drawn: $error',
        ),
      ),
      ArtifactKind.image => Image.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: (context, error, _) => _Unreadable(
          'This image could not be decoded: $error',
        ),
      ),
      ArtifactKind.mermaid => compact
          ? MermaidDiagramView(parseMermaid(text()))
          : MermaidBlock(text()),
      ArtifactKind.markdown => MarkdownMessage(text()),
      ArtifactKind.pdf => const SizedBox.shrink(),
    };
    final key = ValueKey('artifact-content-${artifact.id}-$revision');
    if (artifact.kind == ArtifactKind.html) {
      return KeyedSubtree(key: key, child: drawn);
    }
    if (compact) return KeyedSubtree(key: key, child: drawn);
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.all(Insets.md),
      child: drawn,
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
    child: InlineSpinner(
      size: InlineSpinnerSize.large,
      semanticsLabel: 'Reading the artifact',
    ),
  );
}

class _Unreadable extends StatelessWidget {
  const _Unreadable(this.message);

  final String message;

  @override
  Widget build(BuildContext context) =>
      PanePlaceholder(message: message, icon: AppIcons.warningCircle);
}
