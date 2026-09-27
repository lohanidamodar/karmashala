part of '../data_request.dart';

// Command snippets and terminal presets.

DataRequest<Object?>? _snippetsRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      SnippetsList.name => const SnippetsList(),
      SnippetAdd.name => SnippetAdd(
        id: args.string('id'),
        label: args.string('label'),
        command: args.string('command'),
        shellId: args.optionalString('shell'),
        submit: args.boolean('submit', orElse: false),
      ),
      SnippetEdit.name => SnippetEdit(
        id: args.string('id'),
        label: args.string('label'),
        command: args.string('command'),
        shellId: args.optionalString('shell'),
        submit: args.boolean('submit', orElse: false),
      ),
      SnippetDelete.name => SnippetDelete(args.string('id')),
      PresetSave.name => PresetSave(
        id: args.string('id'),
        presetName: args.string('name'),
        shape: args.value('shape', (json) => json),
      ),
      PresetDelete.name => PresetDelete(args.string('id')),
      _ => null,
    };

/// A request of the snippets and presets.
sealed class SnippetsRequest<R> extends DataRequest<R> {
  const SnippetsRequest();
}

/// Every snippet and every saved preset.
final class SnippetsList extends SnippetsRequest<SnippetsSnapshot> {
  const SnippetsList();

  static const String name = 'snippets.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(SnippetsSnapshot result) => result.toJson();

  @override
  SnippetsSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => SnippetsSnapshot.fromJson(_object(json, kind)));
}

/// Saves a new snippet under the client's [id]; the server flattens the
/// command to one line (`singleLine`), trims the label and stamps the times.
/// Refused for a blank label or command, or a taken id.
final class SnippetAdd extends _SnippetAnswer {
  const SnippetAdd({
    required this.id,
    required this.label,
    required this.command,
    this.shellId,
    this.submit = false,
  });

  static const String name = 'snippets.add';

  final String id;
  final String label;
  final String command;
  final String? shellId;
  final bool submit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'label': label,
    'command': command,
    'shell': shellId,
    'submit': submit,
  };
}

/// Rewrites snippet [id], by the same rules as [SnippetAdd].
final class SnippetEdit extends _SnippetAnswer {
  const SnippetEdit({
    required this.id,
    required this.label,
    required this.command,
    this.shellId,
    this.submit = false,
  });

  static const String name = 'snippets.edit';

  final String id;
  final String label;
  final String command;
  final String? shellId;
  final bool submit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'label': label,
    'command': command,
    'shell': shellId,
    'submit': submit,
  };
}

final class SnippetDelete extends _SnippetsAck {
  const SnippetDelete(this.id);

  static const String name = 'snippets.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Saves a workbench [shape] as [name]. A name already saved is replaced,
/// keeping its id (`presetIdFor`). Answers the preset as stored.
final class PresetSave extends SnippetsRequest<StoredPreset> {
  const PresetSave({
    required this.id,
    required this.presetName,
    required this.shape,
  });

  static const String name = 'presets.save';

  final String id;
  final String presetName;
  final Map<String, Object?> shape;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'name': presetName,
    'shape': shape,
  };

  @override
  Object? resultToJson(StoredPreset result) => result.toJson();

  @override
  StoredPreset resultFromJson(Object? json) =>
      _decode(kind, () => StoredPreset.fromJson(_object(json, kind)));
}

final class PresetDelete extends _SnippetsAck {
  const PresetDelete(this.id);

  static const String name = 'presets.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

sealed class _SnippetsAck extends SnippetsRequest<DataAck> {
  const _SnippetsAck();

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

sealed class _SnippetAnswer extends SnippetsRequest<CommandSnippet> {
  const _SnippetAnswer();

  @override
  Object? resultToJson(CommandSnippet result) => result.toJson();

  @override
  CommandSnippet resultFromJson(Object? json) =>
      _decode(kind, () => CommandSnippet.fromJson(_object(json, kind)));
}
