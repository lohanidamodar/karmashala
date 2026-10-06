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
        reveal: json['reveal'] == 'background'
            ? TabReveal.background
            : TabReveal.front,
      ),
      'openTerminalTab' => OpenTerminalTab(
        paneId: json['paneId']! as String,
        title: json['title']! as String,
      ),
      'closeTerminalTab' => CloseTerminalTab(
        json['paneId']! as String,
        sessionId: json['sessionId'] as String?,
      ),
      'selectCheckout' => SelectCheckout(json['repositoryId']! as String),
      'insertSnippet' => InsertSnippet(
        snippetId: json['snippetId']! as String,
        paneId: json['paneId'] as String?,
      ),
      'openImportedSession' => OpenImportedSession(json['id']! as String),
      'draftForSession' => DraftForSession(
        sessionId: json['sessionId']! as String,
        text: json['text']! as String,
      ),
      _ => null,
    };

/// Something the server asks one desktop client's window to do.
sealed class ClientIntent extends DataChange {
  const ClientIntent();
}

/// How a window shows a tab it is asked to open.
enum TabReveal {
  /// Brought forward and focused: a person asked for it.
  front,

  /// Added behind the tab in front, which keeps the keyboard: another session
  /// started it.
  background,
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
    this.reveal = TabReveal.front,
  });

  final String sessionId;
  final String title;
  final AgentPaneLaunch? launch;

  /// On the wire only when [TabReveal.background], so a client that does not
  /// know the key shows the tab in front, as it always did.
  final TabReveal reveal;

  @override
  Map<String, Object?> toJson() => {
    'change': 'openSessionTab',
    'sessionId': sessionId,
    'title': title,
    if (launch != null) 'launch': agentLaunchToWire(launch!),
    if (reveal == TabReveal.background) 'reveal': 'background',
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
  const CloseTerminalTab(this.paneId, {this.sessionId});

  final String paneId;

  /// The terminal's session at the server, for a window that shows it under
  /// a pane id of its own — an agent's tab it opened itself.
  final String? sessionId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'closeTerminalTab',
    'paneId': paneId,
    'sessionId': ?sessionId,
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

/// Offer [text] to session [sessionId] as a draft: left in its message box,
/// or typed at its prompt unsent, for the person to send or not.
final class DraftForSession extends ClientIntent {
  const DraftForSession({required this.sessionId, required this.text});

  final String sessionId;
  final String text;

  @override
  Map<String, Object?> toJson() => {
    'change': 'draftForSession',
    'sessionId': sessionId,
    'text': text,
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
