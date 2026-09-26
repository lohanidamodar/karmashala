import 'fake_data_server.dart';

/// One machine a test stands up: the fake server its app talks to, and the
/// key a second container over it (a restart) finds its terminal layout by.
class TestMachine {
  FakeDataServer? _server;

  /// The server that [FakeDataServer.runsOn] this machine.
  FakeDataServer get server =>
      _server ?? (throw StateError('no fake server runs on this machine'));
}

/// A [TestMachine] that prices a period of the app's life in what it asks
/// its server: every data request since [reset], by kind.
class CountingMachine extends TestMachine {
  var _from = 0;

  List<String> get _asked => _server?.requests ?? const [];

  void reset() => _from = _asked.length;

  List<String> get statements => _asked.sublist(_from);

  int get count => statements.length;

  static final _read = RegExp(
    r'\.(list|get|recent|forSession|runs|matching|history|events|relays|'
    r'relayCount|lastEventAt|credentials|subscribe|usingEnvironment)$',
  );

  List<String> get reads => statements.where(_read.hasMatch).toList();

  List<String> get writes =>
      statements.where((kind) => !_read.hasMatch(kind)).toList();
}

extension RunsOn on FakeDataServer {
  /// This server is [machine]'s from now on.
  FakeDataServer runsOn(TestMachine machine) {
    machine._server = this;
    return this;
  }
}
