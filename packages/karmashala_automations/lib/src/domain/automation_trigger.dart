/// A moment the app observes reliably enough to start work on. Deliberately
/// few: each one is a status change a hook or a transcript witnessed, not a
/// guess — see `AutomationEventRouter` for the evidence each requires.
enum AutomationEventKind {
  /// An agent's turn ended and it is waiting for its next message. Not the
  /// session ending: a `SessionEnd` (a `/clear`, a quit) is never this.
  turnFinished('turn_finished'),

  /// An agent's turn ended in an error the agent itself reported.
  turnFailed('turn_failed'),

  /// A session started waiting on a person: an open prompt or a question.
  needsYou('needs_you');

  const AutomationEventKind(this.storedName);

  /// What a row stores. Spelled out rather than `name` so a rename in Dart
  /// cannot silently orphan every stored rule.
  final String storedName;

  /// Null for a word this build does not know — a rule from a newer build is
  /// read as matching nothing, never as some other event.
  static AutomationEventKind? fromStored(String? stored) {
    for (final kind in values) {
      if (kind.storedName == stored) return kind;
    }
    return null;
  }

  /// "finishes a turn" — completes "When a session in … ".
  String get phrase => switch (this) {
    AutomationEventKind.turnFinished => 'finishes a turn',
    AutomationEventKind.turnFailed => 'ends a turn in an error',
    AutomationEventKind.needsYou => 'starts waiting on you',
  };

  String get label => switch (this) {
    AutomationEventKind.turnFinished => 'A session finishes a turn',
    AutomationEventKind.turnFailed => 'A session\'s turn fails',
    AutomationEventKind.needsYou => 'A session needs you',
  };
}

/// What an event-triggered automation does. Both are things automations and
/// scheduled resumes already do; an event only changes *when*.
enum AutomationEventAction {
  /// Starts a new session in the automation's checkout with its prompt — the
  /// same gated, checkpointed, undoable run a scheduled automation makes.
  startSession('start_session'),

  /// Types the prompt into the session the event came from, as a scheduled
  /// resume does. Never restarts an ended session and never moves focus.
  messageSession('message_session'),

  /// Starts nothing and tells nobody: only the steps after run, a
  /// notification above all.
  notifyOnly('notify_only');

  const AutomationEventAction(this.storedName);

  final String storedName;

  static AutomationEventAction? fromStored(String? stored) {
    for (final action in values) {
      if (action.storedName == stored) return action;
    }
    return null;
  }

  String get label => switch (this) {
    AutomationEventAction.startSession => 'Start a new session with the prompt',
    AutomationEventAction.messageSession => 'Send the prompt to that session',
    AutomationEventAction.notifyOnly => 'Only notify me',
  };
}

/// When an event-triggered automation fires, and what it then does.
class AutomationEventTrigger {
  const AutomationEventTrigger({required this.kind, required this.action});

  final AutomationEventKind kind;
  final AutomationEventAction action;

  /// Reads back what a row stored; null when either half is missing or from a
  /// newer build, which keeps such a row inert rather than guessing.
  static AutomationEventTrigger? fromRow({String? event, String? action}) {
    final kind = AutomationEventKind.fromStored(event);
    final act = AutomationEventAction.fromStored(action);
    if (kind == null || act == null) return null;
    return AutomationEventTrigger(kind: kind, action: act);
  }

  /// The whole rule in one sentence, for the card and the dialog.
  String describe({required String checkout, required String prompt}) {
    final quoted = prompt.length > 80 ? '${prompt.substring(0, 77)}…' : prompt;
    final what = switch (action) {
      AutomationEventAction.startSession =>
        'start a new session there told "$quoted"',
      AutomationEventAction.messageSession => 'send it "$quoted"',
      AutomationEventAction.notifyOnly => 'notify you',
    };
    return 'When a session in $checkout ${kind.phrase}, $what.';
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationEventTrigger &&
      other.kind == kind &&
      other.action == action;

  @override
  int get hashCode => Object.hash(kind, action);

  @override
  String toString() => 'on ${kind.storedName} -> ${action.storedName}';
}
