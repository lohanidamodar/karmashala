/// What is holding the user up: why a session needs them, and the inbox that
/// queues those — state rather than an interruption, so a missed toast does
/// not lose one. Each value carries its JSON: the server keeps the inbox and
/// tells clients it whole.
library;

export 'src/attention_json.dart' show AttentionFormatException;
export 'src/follow_up_items.dart';
export 'src/inbox_item.dart';
export 'src/session_attention.dart';
