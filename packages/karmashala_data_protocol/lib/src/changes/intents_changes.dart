part of '../data_change.dart';

// What the server asks one desktop client to show (slice 5b): the work is the
// server's — a session it started, a checkout an agent pointed at — and only
// the window is the client's. Told to one client alone (the one a person last
// used, or the only one connected), never to every client, and never kept:
// a client that was not connected when it was asked is simply not asked.

DataChange? _intentsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'openSessionTab' => OpenSessionTab(
        sessionId: json['sessionId']! as String,
        title: json['title']! as String,
        launch: json['launch'] == null
            ? null
            : agentLaunchFromWire(
                (json['launch']! as Map).cast<String, Object?>(),
              ),
      ),
      'openTerminalTab' => OpenTerminalTab(
        paneId: json['paneId']! as String,
        title: json['title']! as String,
      ),
      'closeTerminalTab' => CloseTerminalTab(json['paneId']! as String),
      'selectCheckout' => SelectCheckout(json['repositoryId']! as String),
      'insertSnippet' => InsertSnippet(
        snippetId: json['snippetId']! as String,
        paneId: json['paneId'] as String?,
      ),
      'openImportedSession' => OpenImportedSession(json['id']! as String),
      _ => null,
    };

/// Something the server asks one desktop client's window to do.
sealed class ClientIntent extends DataChange {
  const ClientIntent();
}

/// Show session [sessionId] in a tab: attach a pane to the terminal the
/// server runs it in, or bring forward the pane already showing it. [launch]
/// is what the pane stores; a launch with an SSH host is one the client runs
/// itself (its SSH panes are its own until slice 5d).
final class OpenSessionTab extends ClientIntent {
  const OpenSessionTab({
    required this.sessionId,
    required this.title,
    this.launch,
  });

  final String sessionId;
  final String title;
  final AgentPaneLaunch? launch;

  @override
  Map<String, Object?> toJson() => {
    'change': 'openSessionTab',
    'sessionId': sessionId,
    'title': title,
    if (launch != null) 'launch': agentLaunchToWire(launch!),
  };
}

/// Show the terminal the server runs for pane [paneId] (`terminalSessionId`
/// of the pane) in a tab, attaching only: a Flutter run, a build, a shell an
/// agent opened.
final class OpenTerminalTab extends ClientIntent {
  const OpenTerminalTab({required this.paneId, required this.title});

  final String paneId;
  final String title;

  @override
  Map<String, Object?> toJson() => {
    'change': 'openTerminalTab',
    'paneId': paneId,
    'title': title,
  };
}

/// Close the tab showing pane [paneId]; the server already ended or let go of
/// its terminal.
final class CloseTerminalTab extends ClientIntent {
  const CloseTerminalTab(this.paneId);

  final String paneId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'closeTerminalTab',
    'paneId': paneId,
  };
}

/// Point the sidebar, the diff view and the context panel at checkout
/// [repositoryId].
final class SelectCheckout extends ClientIntent {
  const SelectCheckout(this.repositoryId);

  final String repositoryId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'selectCheckout',
    'repositoryId': repositoryId,
  };
}

/// Type saved snippet [snippetId] into pane [paneId], or the focused pane,
/// and leave it at the prompt (or submit it, when the snippet says so and the
/// pane is a shell).
final class InsertSnippet extends ClientIntent {
  const InsertSnippet({required this.snippetId, this.paneId});

  final String snippetId;
  final String? paneId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'insertSnippet',
    'snippetId': snippetId,
    'paneId': ?paneId,
  };
}

/// Open imported CLI session [importedId] in a terminal window of the
/// client's own machine — the only place its conversation can be resumed from
/// outside Karmashala's own sessions.
final class OpenImportedSession extends ClientIntent {
  const OpenImportedSession(this.importedId);

  final String importedId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'openImportedSession',
    'id': importedId,
  };
}
