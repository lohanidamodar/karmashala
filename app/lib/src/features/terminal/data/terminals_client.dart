import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../environments/application/environments_controller.dart';

/// A terminal the server would not start, or close, in its own words.
class TerminalRefused implements Exception {
  const TerminalRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// **The server's terminals, asked for** (slice 5a): every local and WSL
/// pane is a PTY the server runs, started here by naming a profile or an
/// agent launch — the server builds the argv on its own OS, with its own
/// environment vault — and attached to by session id.
class TerminalsClient {
  const TerminalsClient(this._client);

  final DataClient _client;

  Future<R> _send<R>(TerminalWorkRequest<R> request) async {
    try {
      return (await _client.send(request)).value;
    } on DataRefused catch (refusal) {
      throw TerminalRefused(refusal.message);
    }
  }

  /// The shells the server's machine opens.
  Future<List<TerminalProfile>> profiles() => _send(const TerminalsProfiles());

  /// Starts pane [TerminalOpen.paneId]'s terminal, or answers the one
  /// already running under its id.
  Future<TerminalOpened> open(TerminalOpen request) => _send(request);

  /// Every terminal the server holds, running or ended and kept.
  Future<List<TerminalRecord>> list() => _send(const TerminalsList());

  /// Ends [sessionId] for good. One the server no longer holds is already
  /// ended.
  Future<void> close(String sessionId) async {
    try {
      await _client.send(TerminalClose(sessionId));
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.notFound) return;
      throw TerminalRefused(refusal.message);
    }
  }

  Future<void> rename(String sessionId, String title) =>
      _send(TerminalRename(sessionId, title));
}

final terminalsClientProvider = Provider<TerminalsClient>(
  (ref) => TerminalsClient(ref.watch(dataClientProvider)),
);

/// The shells the server's machine offers — **its** OS, not this one's: a
/// Mac client of a Windows server opens PowerShell there. Asked again when
/// the server comes back and when the environments change (a WSL distro
/// found or removed); empty until the server first answers.
class ServerTerminalProfiles extends Notifier<List<TerminalProfile>> {
  List<TerminalProfile> _last = const [];

  @override
  List<TerminalProfile> build() {
    ref.watch(environmentsControllerProvider);
    final client = ref.watch(dataClientProvider);
    final connection = client.connectionChanges.listen((connection) {
      if (connection.state == DataLinkState.connected) unawaited(_load());
    });
    ref.onDispose(connection.cancel);
    unawaited(_load());
    return _last;
  }

  Future<void> _load() async {
    try {
      final profiles = await ref.read(terminalsClientProvider).profiles();
      _last = profiles;
      if (ref.mounted) state = profiles;
    } on Object {
      // No server yet: the last answer stands; the next connection asks.
    }
  }
}

final terminalServerProfilesProvider =
    NotifierProvider<ServerTerminalProfiles, List<TerminalProfile>>(
      ServerTerminalProfiles.new,
    );
