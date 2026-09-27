import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:path/path.dart' as p;

/// The project directory a tool call names: a checkout id — what carries the
/// environment (§17) — and an optional relative sub-path.
EnvironmentPath projectOfCheckout(
  CheckoutRows rows,
  Map<String, dynamic> args, {
  String example = '"app" or "packages/mobile"',
}) {
  final id = (args['checkoutId'] as String?)?.trim() ?? '';
  if (id.isEmpty) {
    throw ArgumentError(
      'checkoutId is required. list_checkouts has the ids, and the id is '
      'what says which environment the commands run in.',
    );
  }
  final repository = rows.repository(id);
  if (repository == null) {
    throw StateError('No checkout with id $id. list_checkouts has them.');
  }
  final relative = (args['projectDirectory'] as String?)?.trim() ?? '';
  if (relative.isEmpty) return repository.path;
  final environment = rows.environment(repository.path.environmentId);
  final context = environment != null && usesWindowsPaths(environment.kind)
      ? p.windows
      : p.posix;
  if (context.isAbsolute(relative)) {
    throw ArgumentError(
      'projectDirectory is relative to the checkout — $example, not an '
      'absolute path.',
    );
  }
  return repository.path.copyWith(
    path: context.joinAll([repository.path.path, ...relative.split('/')]),
  );
}
