import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_host_protocol/protocol.dart';
import 'package:xterm2/core.dart';

import '../../domain/host_session.dart';
import '../../domain/screen_facts.dart';
import '../../domain/screen_tail.dart';
import '../../domain/write_token.dart';
import 'package:karmashala_ssh_host/host.dart' show BoxRoute;

import 'remote_sessions.dart';

/// **The server's copy of a session on an SSH box** (slice 5d), kept over its
/// own attachment on the box's link: every byte the program writes goes
/// through a screen here, so the server reads the box's panes, agents and
/// runs as it reads its own — a title, a folder, OSC 133, an agent's status,
/// a run's tail. The process and its exit are the box's: the exit told here
/// is the box host's, never a guess.
class BoxScreen implements RemoteSession {
  BoxScreen({
    required this.hostId,
    required this.id,
    required this.startedAt,
    required int columns,
    required int rows,
  }) : _screen = Terminal(maxLines: HostSession.screenScrollbackLines)
         ..resize(columns, rows) {
    facts = ScreenFacts(_screen);
    _screen
      ..onTitleChange = facts!.titleChanged
      ..onCurrentDirectoryChange = facts!.directoryChanged
      ..onPrivateOSC = facts!.osc;
    _input = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_ScreenSink(_screen));
  }

  @override
  final String hostId;

  /// The box host's own id for the session.
  @override
  final String id;

  @override
  final DateTime startedAt;

  /// How a client names it at the server: `ssh:<hostId>/<id>`.
  @override
  String get ref => boxSessionRef(hostId, id);

  @override
  late final ScreenFacts? facts;

  /// Who of the server's clients may type into it and resize it: the box sees
  /// only the server, so the server keeps the one-writer rule itself.
  final WriteToken token = WriteToken();

  final Terminal _screen;
  late final ByteConversionSink _input;
  final _output = StreamController<void>.broadcast(sync: true);
  final _ended = Completer<SessionLifecycle>();
  SessionLifecycle _lifecycle = const SessionRunning();
  BoxRoute? _route;
  StreamSubscription<HostMessage>? _frames;

  /// The next output offset this copy has not seen: where it resumes after
  /// its link was lost.
  int nextOffset = 0;

  @override
  SessionLifecycle get lifecycle => _lifecycle;

  @override
  Future<SessionLifecycle> get ended => _ended.future;

  /// Fires on each chunk of output from now on.
  @override
  Stream<void> get output => _output.stream;

  /// Whether the server's link carries this copy now.
  bool get linked => _route != null;

  @override
  List<String> tailText(int lines) => screenTailOf(_screen, lines: lines);

  /// Follows [route] — the server's own attachment — from now on.
  void follow(BoxRoute route) {
    unawaited(_frames?.cancel());
    _route = route;
    _frames = route.frames.listen(
      _onFrame,
      onDone: () {
        if (_route == route) _route = null;
      },
    );
  }

  /// Types [bytes] as the server itself (a setup command's input, a prompt
  /// answer): refused — false — when the link is down or the session ended.
  @override
  bool type(List<int> bytes) {
    final route = _route;
    if (route == null || _lifecycle.hasEnded) return false;
    route.input(Uint8List.fromList(bytes));
    return true;
  }

  /// A client resized the session at the box; this copy follows.
  void resized(int columns, int rows) => _screen.resize(columns, rows);

  /// Ends the copy without the box saying so — the session was closed from
  /// here and its link dropped before the exit came.
  void endedWithoutWord(String reason) =>
      _end(SessionEndedWithoutCode(DateTime.now().toUtc(), reason));

  void _onFrame(HostMessage message) {
    switch (message) {
      case OutputMessage(:final offset, :final bytes):
        if (offset + bytes.length <= nextOffset) return;
        final skip = offset < nextOffset ? nextOffset - offset : 0;
        final fresh = skip == 0 ? bytes : bytes.sublist(skip);
        _input.add(fresh);
        nextOffset = offset + bytes.length;
        if (!_output.isClosed) _output.add(null);
      case ExitedMessage(:final exitCode, :final reason, :final observedAt):
        _end(
          exitCode != null
              ? SessionExited(exitCode, observedAt.toUtc())
              : SessionEndedWithoutCode(observedAt.toUtc(), reason),
        );
      default:
        break;
    }
  }

  void _end(SessionLifecycle end) {
    if (_lifecycle.hasEnded) return;
    _lifecycle = end;
    if (!_ended.isCompleted) _ended.complete(end);
    unawaited(_frames?.cancel());
    _route?.detach();
    _route = null;
    unawaited(_output.close());
  }

  void dispose() {
    unawaited(_frames?.cancel());
    _route?.detach();
    _route = null;
    if (!_output.isClosed) unawaited(_output.close());
  }
}

class _ScreenSink implements Sink<String> {
  _ScreenSink(this._terminal);
  final Terminal _terminal;

  @override
  void add(String data) => _terminal.write(data);

  @override
  void close() {}
}
