part of '../data_change.dart';

// Command snippets and terminal presets.

DataChange? _snippetsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'snippetChanged' => SnippetChanged(CommandSnippet.fromJson(_row(json))),
      'snippetRemoved' => SnippetRemoved(json['id']! as String),
      'presetChanged' => PresetChanged(StoredPreset.fromJson(_row(json))),
      'presetRemoved' => PresetRemoved(json['id']! as String),
      _ => null,
    };

/// A change to the snippets or the saved presets.
sealed class SnippetsChange extends DataChange {
  const SnippetsChange();
}

final class SnippetChanged extends SnippetsChange {
  const SnippetChanged(this.snippet);

  final CommandSnippet snippet;

  @override
  Map<String, Object?> toJson() => {
    'change': 'snippetChanged',
    'row': snippet.toJson(),
  };
}

final class SnippetRemoved extends SnippetsChange {
  const SnippetRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'snippetRemoved', 'id': id};
}

final class PresetChanged extends SnippetsChange {
  const PresetChanged(this.preset);

  final StoredPreset preset;

  @override
  Map<String, Object?> toJson() => {
    'change': 'presetChanged',
    'row': preset.toJson(),
  };
}

final class PresetRemoved extends SnippetsChange {
  const PresetRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'presetRemoved', 'id': id};
}
