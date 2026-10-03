import 'package:meta/meta.dart';

import '../json.dart';

/// One of the agent's operating modes (ask, edit, plan...).
@immutable
final class SessionMode {
  const SessionMode({required this.id, required this.name, this.description});

  factory SessionMode.fromJson(JsonMap json) => SessionMode(
    id: json.string('id') ?? '',
    name: json.string('name') ?? '',
    description: json.string('description'),
  );

  final String id;
  final String name;
  final String? description;

  JsonMap toJson() =>
      withoutNulls({'id': id, 'name': name, 'description': description});
}

/// The modes a session offers and the one it is in.
@immutable
final class SessionModeState {
  const SessionModeState({
    required this.currentModeId,
    required this.availableModes,
  });

  factory SessionModeState.fromJson(JsonMap json) => SessionModeState(
    currentModeId: json.string('currentModeId') ?? '',
    availableModes: [
      for (final mode in json.objects('availableModes') ?? const <JsonMap>[])
        SessionMode.fromJson(mode),
    ],
  );

  final String currentModeId;
  final List<SessionMode> availableModes;

  JsonMap toJson() => {
    'currentModeId': currentModeId,
    'availableModes': [for (final mode in availableModes) mode.toJson()],
  };
}

/// A choice in a `select` config option.
@immutable
final class ConfigSelectOption {
  const ConfigSelectOption({
    required this.value,
    required this.name,
    this.description,
    this.group,
    this.groupId,
  });

  final String value;
  final String name;
  final String? description;

  /// The group heading this choice sat under, when the agent grouped them.
  final String? group;

  /// That group's id (`group` on the wire).
  final String? groupId;

  bool get _isGrouped => group != null || groupId != null;

  JsonMap toJson() =>
      withoutNulls({'value': value, 'name': name, 'description': description});
}

/// A session setting the agent exposes: a `select` among [options], or a
/// `boolean`. Anything else is kept with its raw [type] and [currentValue].
@immutable
final class ConfigOption {
  const ConfigOption({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    this.category,
    this.currentValue,
    this.options = const [],
  });

  factory ConfigOption.fromJson(JsonMap json) => ConfigOption(
    id: json.string('id') ?? '',
    name: json.string('name') ?? '',
    type: json.string('type') ?? '',
    description: json.string('description'),
    category: json.string('category'),
    currentValue: json['currentValue'],
    options: _selectOptions(json.objects('options')),
  );

  final String id;
  final String name;
  final String type;
  final String? description;
  final String? category;

  /// A `String` value id for `select`, a `bool` for `boolean`.
  final Object? currentValue;
  final List<ConfigSelectOption> options;

  bool get isSelect => type == 'select';
  bool get isBoolean => type == 'boolean';

  JsonMap toJson() => withoutNulls({
    'id': id,
    'name': name,
    'type': type,
    'description': description,
    'category': category,
    'currentValue': currentValue,
    if (isSelect) 'options': _selectOptionsToJson(options),
  });

  /// Grouped and ungrouped lists both flatten to choices; a group's items
  /// remember their heading and id.
  static List<ConfigSelectOption> _selectOptions(List<JsonMap>? items) {
    final result = <ConfigSelectOption>[];
    for (final item in items ?? const <JsonMap>[]) {
      final grouped = item.objects('options');
      if (grouped != null) {
        final heading = item.string('name');
        final groupId = item.string('group');
        for (final choice in grouped) {
          result.add(_choice(choice, group: heading, groupId: groupId));
        }
      } else {
        result.add(_choice(item));
      }
    }
    return result;
  }

  /// [_selectOptions] undone: consecutive choices of one group go back under
  /// it, so a grouped list goes out grouped.
  static List<JsonMap> _selectOptionsToJson(List<ConfigSelectOption> options) {
    final result = <JsonMap>[];
    for (var i = 0; i < options.length; i++) {
      final first = options[i];
      if (!first._isGrouped) {
        result.add(first.toJson());
        continue;
      }
      final members = [first.toJson()];
      while (i + 1 < options.length &&
          options[i + 1]._isGrouped &&
          options[i + 1].group == first.group &&
          options[i + 1].groupId == first.groupId) {
        members.add(options[++i].toJson());
      }
      result.add(
        withoutNulls({
          'group': first.groupId,
          'name': first.group,
          'options': members,
        }),
      );
    }
    return result;
  }

  static ConfigSelectOption _choice(
    JsonMap json, {
    String? group,
    String? groupId,
  }) => ConfigSelectOption(
    value: json.string('value') ?? '',
    name: json.string('name') ?? '',
    description: json.string('description'),
    group: group,
    groupId: groupId,
  );
}

List<ConfigOption>? configOptionsFromJson(List<JsonMap>? items) =>
    items == null ? null : [for (final o in items) ConfigOption.fromJson(o)];
