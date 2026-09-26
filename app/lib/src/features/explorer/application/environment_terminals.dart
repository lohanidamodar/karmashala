/// One terminal a machine is holding.
///
/// **The shape is the session host's, on purpose.** Today only an SSH machine
/// runs one, so a local or WSL row is an open pane instead; when the host runs
/// in every environment the source changes and this does not.
class EnvironmentTerminal {
  const EnvironmentTerminal({
    required this.id,
    required this.label,
    required this.running,
    this.paneId,
    this.hostSessionId,
  });

  final String id;

  /// What it is running, in its own words — the argv, or the pane's title.
  final String label;

  final bool running;

  /// The pane already open here, when there is one: the row focuses it, or
  /// adopts it when the terminal came from a host.
  final String? paneId;

  /// The host's own id, when a host answered rather than a pane being read.
  /// A row with one can be attached to and ended.
  final String? hostSessionId;

  bool get isHosted => hostSessionId != null;
}

/// What one machine answered, and when.
///
/// §19: the reading carries its age, and **"could not look" is a different
/// answer from "nothing is running"** — an empty list with a [problem] set
/// tells the first story, an empty list without one tells the second.
class EnvironmentTerminals {
  const EnvironmentTerminals({
    required this.terminals,
    required this.readAt,
    this.problem,
    this.busy = false,
  });

  /// Nothing has been asked yet. Not an empty machine — an unasked one.
  static const unasked = EnvironmentTerminals(terminals: [], readAt: null);

  final List<EnvironmentTerminal> terminals;

  /// Null means nobody has looked.
  final DateTime? readAt;

  /// The machine's own words for why it could not be asked.
  final String? problem;

  /// A question is in flight. Kept beside the last answer rather than
  /// replacing it, so a refresh does not blank the rows underneath.
  final bool busy;

  bool get asked => readAt != null;

  /// How many are still running, or null when nobody has looked.
  int? get runningCount =>
      asked ? terminals.where((t) => t.running).length : null;
}
