import '../protocol/messages.dart';

/// Where [HostServer] hands each client's terminal panes ([PaneFactsMessage])
/// and tells of a client gone. [client] is the connection, used as a key.
abstract interface class PaneFactsReceiver {
  /// [client]'s panes now — all of them. [send] reaches that client, for the
  /// panes whose tails the server wants next.
  void report(
    Object client,
    List<PaneFacts> panes,
    void Function(HostMessage message) send,
  );

  /// [client]'s link ended: its panes are gone with it.
  void detach(Object client);
}

/// Every client's panes, as last reported, and the tails the server asked
/// for: what adoption and attribution read of the panes they cannot see.
class ClientPanes implements PaneFactsReceiver {
  final Map<Object, _Client> _clients = {};

  /// Called after each report and each client gone, with every pane every
  /// client has now.
  void Function(List<PaneFacts> panes)? onChanged;

  /// Every pane every client has now.
  List<PaneFacts> get all => [
    for (final client in _clients.values) ...client.panes.values,
  ];

  /// Every tail the clients sent since the last take, by pane — each used
  /// once, so a screen is never read long after it was drawn.
  Map<String, List<String>> takeTails() {
    final taken = <String, List<String>>{};
    for (final client in _clients.values) {
      taken.addAll(client.tails);
      client.tails.clear();
    }
    return taken;
  }

  @override
  void report(
    Object client,
    List<PaneFacts> panes,
    void Function(HostMessage message) send,
  ) {
    final entry = _clients[client] ??= _Client(send);
    entry.panes
      ..clear()
      ..addEntries([
        for (final pane in panes) MapEntry(pane.paneId, pane.withoutTail()),
      ]);
    for (final pane in panes) {
      final tail = pane.tail;
      if (tail != null) entry.tails[pane.paneId] = tail;
    }
    entry.tails.removeWhere((paneId, _) => !entry.panes.containsKey(paneId));
    onChanged?.call(all);
  }

  @override
  void detach(Object client) {
    if (_clients.remove(client) != null) onChanged?.call(all);
  }

  /// Asks each client holding one of [paneIds] for their bottom [lines] rows
  /// with its next report. Nothing is asked of a client with none of them.
  void want(Iterable<String> paneIds, int lines) {
    if (lines <= 0) return;
    final wanted = paneIds.toSet();
    if (wanted.isEmpty) return;
    for (final client in _clients.values) {
      final ids = [
        for (final paneId in client.panes.keys)
          if (wanted.contains(paneId)) paneId,
      ];
      if (ids.isEmpty) continue;
      client.send(PaneTailsWantedMessage(paneIds: ids, lines: lines));
    }
  }
}

class _Client {
  _Client(this.send);

  final void Function(HostMessage message) send;
  final Map<String, PaneFacts> panes = {};
  final Map<String, List<String>> tails = {};
}
