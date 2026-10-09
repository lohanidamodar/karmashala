import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../app/shell/workbench_tabs.dart' show openRunningTab;
import '../../../../app/widgets/dashboard_glance.dart';
import '../../../running/application/running_glance.dart';
import '../../../running/application/running_providers.dart';
import '../overview_glances.dart' show GlanceNote;

/// **Running**: how many ports and servers listen, and the newest of them.
const runningGlance = DashboardGlance(
  id: 'running',
  title: 'Running',
  icon: AppIcons.listMagnifyingGlass,
  build: _body,
  onOpen: _open,
);

Widget _body(BuildContext context) => const RunningGlanceBody();

void _open(BuildContext context, WidgetRef ref) => openRunningTab(ref);

class RunningGlanceBody extends ConsumerStatefulWidget {
  const RunningGlanceBody({super.key});

  @override
  ConsumerState<RunningGlanceBody> createState() => _RunningGlanceBodyState();
}

class _RunningGlanceBodyState extends ConsumerState<RunningGlanceBody> {
  @override
  void initState() {
    super.initState();
    // Nothing reads on its own: the glance asks once, as the tab does.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final snapshot = ref.read(runningProvider);
      if (snapshot.reading == null && !snapshot.loading) {
        ref.read(runningProvider.notifier).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final glance = ref.watch(runningGlanceProvider);
    final theme = Theme.of(context);
    final servers = glance.servers;
    if (servers == null) {
      if (glance.error case final error?) {
        return GlanceNote('Not read: $error');
      }
      return const Row(
        children: [
          InlineSpinner(semanticsLabel: 'Reading what runs'),
          SizedBox(width: Insets.xs),
          Flexible(child: GlanceNote('Reading what runs…')),
        ],
      );
    }
    if (servers == 0) return const GlanceNote('Nothing is listening.');
    final newest = glance.newest;
    final count = servers == 1
        ? '1 port listening'
        : '$servers ports listening';
    if (GlanceScope.compactOf(context)) {
      return Text(
        newest == null ? count : '$count · newest ${newest.words}',
        key: const ValueKey('running-glance-line'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          count,
          key: const ValueKey('running-glance-count'),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (newest != null)
          Text(
            'Newest: ${newest.words}',
            key: const ValueKey('running-glance-newest'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UiDensity.of(context).muted(theme),
          ),
      ],
    );
  }
}
