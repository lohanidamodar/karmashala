part of '../data_change.dart';

// Terminals the server runs (slice 5a), told to every desktop client as the
// server's own copy of each screen reads them: a title, a directory, the last
// command, an exit.

DataChange? _terminalsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'terminalChanged' => TerminalChanged(TerminalRecord.fromJson(_row(json))),
      'terminalRemoved' => TerminalRemoved(
        json['id']! as String,
        closed: json['closed'] == true,
      ),
      _ => null,
    };

/// What the server's terminals are doing.
sealed class TerminalChange extends DataChange {
  const TerminalChange();
}

/// A terminal started, or its screen moved something a client shows: its
/// title (OSC 0/2, or a rename), its directory (OSC 7), its last command
/// (OSC 133), or its end.
final class TerminalChanged extends TerminalChange {
  const TerminalChanged(this.terminal);

  final TerminalRecord terminal;

  @override
  Map<String, Object?> toJson() => {
    'change': 'terminalChanged',
    'row': terminal.toJson(),
  };
}

/// Terminal [sessionId] is gone: closed on request, or its ended record
/// pruned.
final class TerminalRemoved extends TerminalChange {
  const TerminalRemoved(this.sessionId, {this.closed = false});

  final String sessionId;

  /// Closed on request, so every window drops its tab; false for a record
  /// pruned, whose tab may still hold history someone kept.
  final bool closed;

  @override
  Map<String, Object?> toJson() => {
    'change': 'terminalRemoved',
    'id': sessionId,
    if (closed) 'closed': true,
  };
}
