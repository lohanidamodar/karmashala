part of '../data_request.dart';

// The folders pinned to every file browser's quick-access column, kept by the
// server so every client — a desktop, a phone — shows the same ones. Each
// request answers the whole list as it now stands, and every client is told
// it (`quickAccessChanged`). A phone may pin: nothing on disk changes.

DataRequest<Object?>? _quickAccessRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  QuickAccessList.name => const QuickAccessList(),
  QuickAccessPinFolder.name => QuickAccessPinFolder(
    QuickAccessPin(
      environmentId: args.string('environmentId'),
      path: args.string('path'),
      label: args.optionalString('label'),
    ),
  ),
  QuickAccessUnpin.name => QuickAccessUnpin(
    environmentId: args.string('environmentId'),
    path: args.string('path'),
  ),
  QuickAccessRename.name => QuickAccessRename(
    environmentId: args.string('environmentId'),
    path: args.string('path'),
    label: args.optionalString('label'),
  ),
  _ => null,
};

/// A request of the quick-access pins; each answers the list as it stands.
sealed class QuickAccessRequest extends DataRequest<List<QuickAccessPin>> {
  const QuickAccessRequest();

  @override
  Object? resultToJson(List<QuickAccessPin> result) => [
    for (final pin in result) pin.toJson(),
  ];

  @override
  List<QuickAccessPin> resultFromJson(Object? json) => _decode(
    kind,
    () => [
      for (final item in _objects(json, kind)) QuickAccessPin.fromJson(item),
    ],
  );
}

final class QuickAccessList extends QuickAccessRequest {
  const QuickAccessList();

  static const String name = 'quickAccess.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};
}

/// Pins [pin] at the end of the list. A folder already pinned keeps its place
/// and takes [pin]'s label when one is given. Refused for a blank or relative
/// path, or past [QuickAccessPin.maxPins].
final class QuickAccessPinFolder extends QuickAccessRequest {
  const QuickAccessPinFolder(this.pin);

  static const String name = 'quickAccess.pin';

  final QuickAccessPin pin;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => pin.toJson();
}

/// Unpins the folder at [path] in [environmentId]; nothing pinned there is
/// not an error.
final class QuickAccessUnpin extends QuickAccessRequest {
  const QuickAccessUnpin({required this.environmentId, required this.path});

  static const String name = 'quickAccess.unpin';

  final String environmentId;
  final String path;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environmentId': environmentId,
    'path': path,
  };
}

/// Names the pinned folder at [path] [label], or by its own name again when
/// [label] is null or blank. Refused `notFound` for a folder not pinned.
final class QuickAccessRename extends QuickAccessRequest {
  const QuickAccessRename({
    required this.environmentId,
    required this.path,
    this.label,
  });

  static const String name = 'quickAccess.rename';

  final String environmentId;
  final String path;
  final String? label;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environmentId': environmentId,
    'path': path,
    'label': ?label,
  };
}
