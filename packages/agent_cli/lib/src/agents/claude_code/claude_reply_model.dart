/// The model a Claude Code record says wrote it: an `assistant` entry's
/// `message.model`. Null for every other record, a subagent's (its own file
/// says what it ran) and `<synthetic>`, a reply Claude Code wrote itself.
String? claudeReplyModel(Map<String, Object?> json) {
  if (json['type'] != 'assistant' || json['isSidechain'] == true) return null;
  final message = json['message'];
  if (message is! Map) return null;
  final model = message['model'];
  if (model is! String || model.isEmpty || model == '<synthetic>') return null;
  return model;
}
