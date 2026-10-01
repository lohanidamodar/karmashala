part of 'fake_data_server.dart';

/// The server's environment vault (slice 5a), in memory and write-only as
/// the real one: a test may look at [values] (what the server would lay
/// over a launch), a client only ever hears names.
class FakeEnvVault {
  FakeEnvVault._(this._server);

  final FakeDataServer _server;

  /// Name → value, as the server holds them.
  final values = <String, String>{};
  final _updated = <String, DateTime>{};

  /// The names, by name, as a client is told them.
  List<EnvVariableName> get names => [
    for (final name in values.keys.toList()..sort())
      EnvVariableName(name: name, updatedAt: _updated[name]!),
  ];

  /// Seeds [name] as if a client had set it before the test.
  void seed(String name, String value, {DateTime? at}) {
    values[name] = value;
    _updated[name] = at ?? _server._now();
  }

  Object? _handle(EnvVaultRequest<Object?> request) {
    switch (request) {
      case EnvList():
        return names;
      case EnvSet(:final variable, :final value):
        final name = variable.trim();
        final refused = envNameRefusal(name) ?? envValueRefusal(value);
        if (refused != null) throw DataRefused.invalid(refused);
        seed(name, value);
      case EnvRemove(:final variable):
        if (values.remove(variable.trim()) == null) return const DataAck();
        _updated.remove(variable.trim());
      case EnvRename(:final from, :final to, :final value):
        final source = from.trim();
        final target = to.trim();
        final refused =
            envNameRefusal(target) ??
            (value == null ? null : envValueRefusal(value)) ??
            envRenameRefusal(source, target, values.keys);
        if (refused != null) throw DataRefused.invalid(refused);
        final moved = values.remove(source)!;
        _updated.remove(source);
        seed(target, value ?? moved);
    }
    // Told to every link, the asker's too, as the server announces it.
    _server._tell(null, [EnvVariablesChanged(names)]);
    return const DataAck();
  }
}
