/// Webhooks: the template a call fills, how its signature is checked, and the
/// ids and secrets a hook is given. Pure, so the app's test call and the
/// server's real one read a template the same way.
library;

export 'src/domain/automation_webhook.dart';
export 'src/domain/webhook_call.dart';
export 'src/domain/webhook_template.dart';
export 'src/domain/webhook_verification.dart';
