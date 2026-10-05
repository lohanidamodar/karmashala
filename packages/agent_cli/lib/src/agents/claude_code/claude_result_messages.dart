/// What a Claude tool's structured result (its `toolUseResult`) says in one
/// sentence — a TaskStop's or a SendMessage's `message` — where its text is
/// JSON; null for any other result.
String? claudeResultMessage(Object? result) {
  if (result is! Map) return null;
  final message = result['message'];
  if (message is! String || message.trim().isEmpty) return null;
  final speaks =
      result.containsKey('task_type') ||
      (result['success'] is bool && !result.containsKey('commandName'));
  return speaks ? message.trim() : null;
}
