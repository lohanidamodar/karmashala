import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/phone_more_page.dart' show PhoneMoreList;
import '../../../app/shell/phone_routes.dart' show PhoneMoreEntry;
import '../application/todos_providers.dart';
import '../domain/project_scope.dart';

/// The todos as a page of their own over where the person is — the phone's,
/// from the Dashboard's header or a session's ⋯ — the same page as More's
/// Todos. [scope] lands it on one project's.
void openTodosPage(BuildContext context, WidgetRef ref, {ProjectScope? scope}) {
  if (scope != null) ref.read(todoScopeProvider.notifier).select(scope);
  Navigator.of(context).push(PhoneMoreList.routeFor(PhoneMoreEntry.todos));
}
