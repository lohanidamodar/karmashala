/// A refusal said twice: [message] short and plain enough for a pane's one
/// line, [detail] the whole technical account — folders searched, addresses,
/// protocol versions — for the log and a pane's Details.
abstract interface class ExplainedFailure implements Exception {
  String get message;

  /// Null when [message] is the whole account.
  String? get detail;
}
