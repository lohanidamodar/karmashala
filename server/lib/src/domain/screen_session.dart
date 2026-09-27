import 'package:karmashala_host_protocol/protocol.dart';

import 'screen_facts.dart';

/// A session whose screen the server holds a copy of: one of its own PTYs
/// (`HostSession`), or one on an SSH box it keeps a copy of over its link
/// (`BoxScreen`, slice 5d). What terminals' records, an agent's status and a
/// run's tail are read from, wherever the process runs.
abstract interface class ScreenSession {
  String get id;
  DateTime get startedAt;
  SessionLifecycle get lifecycle;

  /// Completes with how it ended.
  Future<SessionLifecycle> get ended;

  /// What the program told its terminal; null when nobody watched its screen.
  ScreenFacts? get facts;

  /// The last [lines] rows of the screen and its scrollback, as plain text.
  List<String> tailText(int lines);
}
