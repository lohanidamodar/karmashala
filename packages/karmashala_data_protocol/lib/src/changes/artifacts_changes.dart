part of '../data_change.dart';

DataChange? _artifactsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'artifactChanged' => ArtifactChanged(artifactFromJson(_row(json))),
      'visualChanged' => VisualChanged(sessionVisualFromJson(_row(json))),
      _ => null,
    };

/// What an agent showed, as it changes.
sealed class ArtifactChange extends DataChange {
  const ArtifactChange();
}

/// An artifact shown, revised, renamed, or found missing at its source. A
/// client copy holding an older revision reloads its content.
final class ArtifactChanged extends ArtifactChange {
  const ArtifactChanged(this.artifact);

  final Artifact artifact;

  @override
  Map<String, Object?> toJson() => {
    'change': 'artifactChanged',
    'row': artifactToClientJson(artifact),
  };
}

/// A visual drawn or updated in place by `visualize`.
final class VisualChanged extends ArtifactChange {
  const VisualChanged(this.visual);

  final SessionVisual visual;

  @override
  Map<String, Object?> toJson() => {
    'change': 'visualChanged',
    'row': sessionVisualToJson(visual),
  };
}
