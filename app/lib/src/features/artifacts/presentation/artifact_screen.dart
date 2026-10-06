import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/artifact_providers.dart';
import 'artifact_viewer.dart';

/// An artifact full screen — the phone's way in, and a narrow window's. Its
/// content comes over the data channel, the relay on a phone.
class ArtifactScreen extends ConsumerWidget {
  const ArtifactScreen({
    required this.sessionId,
    required this.artifactId,
    super.key,
  });

  final String sessionId;
  final String artifactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artifact = ref.watch(
      sessionArtifactProvider((sessionId: sessionId, id: artifactId)),
    );
    return Scaffold(
      appBar: AppBar(title: Text(artifact?.title ?? 'Artifact')),
      body: SafeArea(
        child: ArtifactViewer(sessionId: sessionId, artifactId: artifactId),
      ),
    );
  }
}
