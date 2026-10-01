part of '../data_request.dart';

// The server's environment vault (slice 5a): the variables it lays over every
// terminal it starts. **Write-only**: a client lists names, sets a value,
// renames one and removes one; no answer, change, log line or `toString` ever carries a value
// (a request prints its kind alone). Answered when done — the vault is a file.

DataRequest<Object?>? _envRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      EnvList.name => const EnvList(),
      EnvSet.name => EnvSet(args.string('name'), args.string('value')),
      EnvRemove.name => EnvRemove(args.string('name')),
      EnvRename.name => EnvRename(
        args.string('from'),
        args.string('to'),
        value: args.optionalString('value'),
      ),
      _ => null,
    };

/// Work on the server's environment vault; answered when done.
sealed class EnvVaultRequest<R> extends DataRequest<R> {
  const EnvVaultRequest();
}

/// The names the vault holds, by name, with when each was set. Never values.
final class EnvList extends EnvVaultRequest<List<EnvVariableName>> {
  const EnvList();

  static const String name = 'env.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<EnvVariableName> result) => [
    for (final variable in result) variable.toJson(),
  ];

  @override
  List<EnvVariableName> resultFromJson(Object? json) => _decode(
    kind,
    () => [
      for (final item in _objects(json, kind)) EnvVariableName.fromJson(item),
    ],
  );
}

/// Sets [variable] to [value], replacing any value it had. [value] travels
/// client → server here only, and is never answered or told.
final class EnvSet extends EnvVaultRequest<DataAck> {
  const EnvSet(this.variable, this.value);

  static const String name = 'env.set';

  final String variable;
  final String value;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'name': variable, 'value': value};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Renames [from] to [to] in one write, so the vault never holds both: the
/// value moves with it, or becomes [value] when one is given. The client
/// cannot read a value, so only the server can carry one across. Refused when
/// [from] is not set or [to] is another variable that is.
final class EnvRename extends EnvVaultRequest<DataAck> {
  const EnvRename(this.from, this.to, {this.value});

  static const String name = 'env.rename';

  final String from;
  final String to;

  /// The new value, travelling client → server only; null keeps the old one.
  final String? value;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'from': from,
    'to': to,
    'value': ?value,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Removes [variable]; removing one that is not there is not a refusal.
final class EnvRemove extends EnvVaultRequest<DataAck> {
  const EnvRemove(this.variable);

  static const String name = 'env.remove';

  final String variable;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'name': variable};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
