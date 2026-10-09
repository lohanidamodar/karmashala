import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../app/shell/phone_routes.dart';
import '../../../../app/shell/side_panel_state.dart';
import '../../../../app/widgets/dashboard_glance.dart';
import '../../../todos/application/todos_providers.dart';
import '../../../todos/presentation/todos_page.dart';
import '../overview_glances.dart' show GlanceNote;

/// The most open todos the glance lists.
const int kTodosGlanceShown = 3;

/// **Todos**: how many are open, the first three, and a line to add one.
const todosGlance = DashboardGlance(
  id: 'todos',
  title: 'Todos',
  icon: AppIcons.listChecks,
  build: _body,
  onOpen: _open,
);

Widget _body(BuildContext context) => const TodosGlanceBody();

/// The phone's Todos page; the side panel's Todos elsewhere.
void _open(BuildContext context, WidgetRef ref) {
  if (ref.read(phoneShellRouterProvider).current != null) {
    openTodosPage(context, ref);
  } else {
    ref.read(sidePanelProvider.notifier).show(SidePanelSurface.todos);
  }
}

class TodosGlanceBody extends ConsumerStatefulWidget {
  const TodosGlanceBody({super.key});

  @override
  ConsumerState<TodosGlanceBody> createState() => _TodosGlanceBodyState();
}

class _TodosGlanceBodyState extends ConsumerState<TodosGlanceBody> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add() {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    ref.read(todosProvider.notifier).add(body: body);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final open = [
      for (final todo in ref.watch(todosProvider))
        if (!todo.isDone) todo,
    ];
    final muted = UiDensity.of(context).muted(theme);
    if (GlanceScope.compactOf(context)) {
      // One line on a phone; adding goes to the Todos page, its box focused.
      return Row(
        children: [
          Expanded(
            child: Text(
              open.isEmpty
                  ? 'Nothing to do.'
                  : '${open.length} open · ${open.first.body}',
              key: const ValueKey('todos-glance-line'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: open.isEmpty ? muted : theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            key: const ValueKey('todos-glance-add-button'),
            tooltip: 'Add a todo',
            visualDensity: VisualDensity.compact,
            iconSize: UiDensity.of(context).iconSmall,
            onPressed: () {
              ref.read(todoComposerFocusProvider.notifier).request();
              _open(context, ref);
            },
            icon: const Icon(AppIcons.plus),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (open.isEmpty)
          const GlanceNote('Nothing to do.')
        else ...[
          Text(
            open.length == 1 ? '1 open' : '${open.length} open',
            key: const ValueKey('todos-glance-count'),
            style: muted,
          ),
          for (final todo in open.take(kTodosGlanceShown))
            Padding(
              key: ValueKey('todos-glance-item:${todo.id}'),
              padding: const EdgeInsets.only(top: Insets.xxs),
              child: Row(
                children: [
                  Icon(
                    AppIcons.circle,
                    size: UiDensity.of(context).iconSmall,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs),
                  Expanded(
                    child: Text(
                      todo.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: Insets.xs),
        TextField(
          key: const ValueKey('todos-glance-add'),
          controller: _text,
          style: theme.textTheme.bodySmall,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Add a todo…',
            suffixIcon: IconButton(
              key: const ValueKey('todos-glance-add-button'),
              tooltip: 'Add',
              visualDensity: VisualDensity.compact,
              iconSize: UiDensity.of(context).iconSmall,
              onPressed: _add,
              icon: const Icon(AppIcons.plus),
            ),
          ),
        ),
      ],
    );
  }
}
