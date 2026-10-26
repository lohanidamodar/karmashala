import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../app/shell/workbench_tabs.dart' show openSettingsTab;
import '../../../../app/widgets/adaptive_modal.dart';
import '../../../../core/capabilities/capabilities.dart';
import '../../../../core/util/failure_words.dart';
import '../../../agents/application/agent_providers.dart';
import '../../../projects/application/projects_controller.dart';
import '../../../sessions/application/session_ui_providers.dart';
import '../../../settings/presentation/settings_catalog.dart';
import '../application/timeline_controller.dart';
import '../domain/timeline_model.dart';
import 'timeline_chart.dart';
import 'timeline_detail.dart';
import 'timeline_painters.dart';

export 'timeline_chart.dart' show kTimelinePhoneWidth;

/// The projects the timeline may show as rows, by id and name.
final timelineProjectChoicesProvider =
    Provider<List<({String id, String name})>>((ref) {
      return [
        for (final project in ref.watch(projectsControllerProvider))
          (id: project.id, name: project.name),
      ];
    });

/// **The Overview tab's Timeline**: what happened, when — drawn from the
/// server's activity log, so it outlives the sessions it shows.
class OverviewTimelineView extends ConsumerStatefulWidget {
  const OverviewTimelineView({
    this.onOpenSession,
    this.onUpdateServer,
    this.clock,
    super.key,
  });

  /// Opens a session's tab. Defaults to selecting it.
  final void Function(String sessionId)? onOpenSession;

  /// Opens Settings → Server, where an older server is updated. Defaults to
  /// the Settings tab.
  final VoidCallback? onUpdateServer;

  /// For tests: what "now" is.
  final DateTime Function()? clock;

  @override
  ConsumerState<OverviewTimelineView> createState() =>
      _OverviewTimelineViewState();
}

class _OverviewTimelineViewState extends ConsumerState<OverviewTimelineView> {
  final _zoom = TimelineZoomController();
  Timer? _ticker;
  late DateTime _now;
  List<ActivityEntry>? _builtFrom;
  TimelineRange? _builtFor;
  DateTime? _builtAt;
  TimelineModel _model = TimelineModel.empty;
  String? _selected;

  DateTime _clock() => (widget.clock ?? DateTime.now)().toUtc();

  @override
  void initState() {
    super.initState();
    _now = _clock();
    // Live bars grow at the right edge; a minute is as fine as a bar reads.
    _ticker = ForegroundTimer.periodic(const Duration(seconds: 30), (_) {
      if (_model.sessions.any((s) => s.live)) {
        setState(() => _now = _clock());
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _zoom.dispose();
    super.dispose();
  }

  TimelineModel _modelFor(List<ActivityEntry> entries, TimelineRange range) {
    if (!identical(entries, _builtFrom) ||
        range != _builtFor ||
        _now != _builtAt) {
      _model = buildTimeline(
        entries,
        from: range.from.toUtc(),
        to: range.to.toUtc(),
        now: _now,
      );
      _builtFrom = entries;
      _builtFor = range;
      _builtAt = _now;
    }
    return _model;
  }

  void _open(TimelineSession session) {
    final open = widget.onOpenSession;
    if (open != null) {
      open(session.id);
    } else {
      ref.read(selectedSessionIdProvider.notifier).select(session.id);
    }
  }

  String _agentName(String id) =>
      ref.read(agentRegistryProvider).displayNameFor(id);

  @override
  Widget build(BuildContext context) {
    final range = ref.watch(timelineRangeProvider);
    final filter = ref.watch(timelineProjectFilterProvider);
    final view = ref.watch(timelineViewFilterProvider);
    final query = TimelineQuery(
      from: range.from,
      to: range.to,
      projectIds: filter,
    );
    final entries = ref.watch(timelineEntriesProvider(query));
    final model = switch (entries) {
      AsyncData(:final value) => _modelFor(value, range),
      _ => null,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final phone = constraints.maxWidth < kTimelinePhoneWidth;
        final docked =
            constraints.maxWidth >=
            WidthClass.scaleBreakpoint(
                  WidthClass.expandedMin,
                  MediaQuery.textScalerOf(context),
                ) +
                Chrome.peekMinWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(
              range: range,
              phone: phone,
              zoom: _zoom,
              waiting: model == null
                  ? 0
                  : model.sessions
                        .where((s) => s.stateNow == TimelineState.waiting)
                        .length,
              machines: {
                for (final s in model?.sessions ?? const <TimelineSession>[])
                  ?s.machine,
              }.toList()..sort(),
            ),
            if (!phone) const _Legend(),
            const Divider(height: Insets.hair),
            Expanded(
              child: switch (entries) {
                AsyncData() => _body(
                  model!.where(view.admits),
                  view: view,
                  docked: docked,
                ),
                // Riverpod retries a failure as loading-with-error.
                AsyncValue(:final error?) => _failure(error),
                _ => const Center(
                  child: InlineSpinner(size: InlineSpinnerSize.large),
                ),
              },
            ),
          ],
        );
      },
    );
  }

  Widget _failure(Object error) {
    // A server from before the activity log refuses the request outright.
    if (!ref.read(capabilitiesProvider).serverOffers(ActivityRange.feature)) {
      return _Message(
        key: const ValueKey('timeline-older-server'),
        text:
            "This server is older than the app and can't show the Timeline. "
            'Update the server in Settings → Server.',
        action: OutlinedButton(
          key: const ValueKey('timeline-update-server'),
          onPressed:
              widget.onUpdateServer ??
              () => openSettingsTab(ref, section: SettingsSectionId.server),
          child: const Text('Open Settings → Server'),
        ),
      );
    }
    return _Message(
      key: const ValueKey('timeline-error'),
      text: 'The timeline could not be read: ${describeFailure(error)}',
    );
  }

  TimelineSession? _find(TimelineModel model, String? id) =>
      id == null ? null : model.sessions.where((s) => s.id == id).firstOrNull;

  Widget _detailFor(
    TimelineModel model,
    TimelineSession session, {
    VoidCallback? onClose,
    void Function(TimelineSession session)? onSelect,
  }) {
    final agent = session.agent;
    return TimelineDetail(
      session: session,
      parent: _find(model, session.parentId),
      children: [
        for (final s in model.sessions)
          if (s.parentId == session.id) s,
      ],
      agentName: agent == null ? null : _agentName(agent),
      onOpen: session.deleted ? null : () => _open(session),
      onSelect: onSelect ?? _select,
      onClose: onClose,
    );
  }

  void _select(TimelineSession session) =>
      setState(() => _selected = session.id);

  Future<void> _sheet(TimelineModel model, TimelineSession session) async {
    setState(() => _selected = session.id);
    await showAdaptiveModal<void>(
      context: context,
      title: session.projectName,
      heightFactor: 0.6,
      builder: (context) => _detailFor(
        model,
        session,
        onSelect: (other) {
          Navigator.of(context).pop();
          _sheet(model, other);
        },
      ),
    );
  }

  Widget _body(
    TimelineModel model, {
    required TimelineViewFilter view,
    required bool docked,
  }) {
    if (model.sessionCount == 0) {
      return _Message(
        key: const ValueKey('timeline-empty'),
        text: _model.sessionCount > 0
            ? 'Nothing here matches the filters.'
            : 'Nothing recorded in this range. Sessions deleted before the '
                  'timeline existed cannot be shown.',
      );
    }
    final selected = _find(model, _selected);
    final chart = TimelineChart(
      model: model,
      now: _now,
      selectedId: selected?.id,
      waitsOnly: view.waitsOnly,
      agentName: _agentName,
      controller: _zoom,
      onSelect: docked ? _select : (session) => _sheet(model, session),
    );
    if (!docked || selected == null) return chart;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: chart),
        const VerticalDivider(width: Insets.hair),
        SizedBox(
          width: Chrome.peekMinWidth,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: _detailFor(
              model,
              selected,
              onClose: () => setState(() => _selected = null),
            ),
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, super.key});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(Insets.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (action case final action?) ...[
            const SizedBox(height: Insets.md),
            action,
          ],
        ],
      ),
    ),
  );
}

String _rangeLabel(TimelineRange range, {bool short = false}) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String day(DateTime d) =>
      '${d.day} ${months[d.month - 1]}${short ? '' : ' ${d.year}'}';
  if (range.isOneDay) return day(range.from);
  final last = DateTime(range.to.year, range.to.month, range.to.day - 1);
  return '${day(range.from)} – ${day(last)}';
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.range,
    required this.phone,
    required this.zoom,
    required this.waiting,
    required this.machines,
  });

  final TimelineRange range;
  final bool phone;
  final TimelineZoomController zoom;

  /// How many wait on the owner right now.
  final int waiting;

  /// The machines the range's sessions ran on.
  final List<String> machines;

  Future<void> _pickRange(BuildContext context, WidgetRef ref) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(
        start: range.from,
        end: DateTime(range.to.year, range.to.month, range.to.day - 1),
      ),
    );
    if (picked != null) {
      ref.read(timelineRangeProvider.notifier).days(picked.start, picked.end);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(timelineRangeProvider.notifier);
    final view = ref.watch(timelineViewFilterProvider);
    final projects = ref.watch(timelineProjectFilterProvider);
    final step = range.isOneDay ? 'day' : 'range';
    final semantic = SemanticColors.of(context);
    final filters = [
      projects != null,
      view.machines != null,
      phone && view.query.trim().isNotEmpty,
    ].where((set) => set).length;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('timeline-previous'),
                tooltip: 'Previous $step',
                icon: const Icon(AppIcons.caretLeft),
                onPressed: controller.previous,
              ),
              Flexible(
                child: TextButton(
                  key: const ValueKey('timeline-range'),
                  onPressed: () => _pickRange(context, ref),
                  child: Text(
                    _rangeLabel(range, short: phone),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('timeline-next'),
                tooltip: 'Next $step',
                icon: const Icon(AppIcons.caretRight),
                onPressed: controller.next,
              ),
              TextButton(
                key: const ValueKey('timeline-today'),
                onPressed: controller.today,
                child: const Text('Today'),
              ),
            ],
          ),
          CompactSegmented<bool>(
            key: const ValueKey('timeline-span'),
            segments: const [
              ButtonSegment(value: true, label: Text('Day')),
              ButtonSegment(value: false, label: Text('Week')),
            ],
            selected: range.isOneDay,
            onChanged: (day) => day ? controller.day() : controller.week(),
          ),
          FilterFunnelButton(
            key: const ValueKey('timeline-projects'),
            count: filters,
            onPressed: () => showAdaptiveModal<void>(
              context: context,
              title: 'Timeline filters',
              builder: (context) => _Filters(machines: machines, search: phone),
            ),
          ),
          // A phone finds by name in the filters; its row keeps to the day.
          if (!phone)
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: Chrome.peekMinWidth / 2,
              ),
              child: const _Search(),
            ),
          FilterChip(
            key: const ValueKey('timeline-waits-only'),
            avatar: Icon(
              AppIcons.question,
              size: Chrome.iconSmall,
              color: semantic.attention,
            ),
            label: Text(waiting > 0 ? 'Waits · $waiting now' : 'Waits only'),
            selected: view.waitsOnly,
            onSelected: ref.read(timelineViewFilterProvider.notifier).waitsOnly,
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A thumb pinches and drags instead.
              if (!phone) ...[
                IconButton(
                  key: const ValueKey('timeline-zoom-out'),
                  tooltip: 'Zoom out',
                  icon: const Icon(AppIcons.magnifyingGlassMinus),
                  onPressed: zoom.zoomOut,
                ),
                IconButton(
                  key: const ValueKey('timeline-zoom-in'),
                  tooltip: 'Zoom in (or Ctrl and scroll)',
                  icon: const Icon(AppIcons.magnifyingGlassPlus),
                  onPressed: zoom.zoomIn,
                ),
              ],
              TextButton(
                key: const ValueKey('timeline-fit'),
                onPressed: zoom.fit,
                child: const Text('Fit'),
              ),
              TextButton.icon(
                key: const ValueKey('timeline-now'),
                icon: const Icon(AppIcons.target),
                onPressed: zoom.now,
                label: const Text('Now'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Words a session's title must hold; it keeps them when it is rebuilt.
class _Search extends ConsumerStatefulWidget {
  const _Search();

  @override
  ConsumerState<_Search> createState() => _SearchState();
}

class _SearchState extends ConsumerState<_Search> {
  late final _controller = TextEditingController(
    text: ref.read(timelineViewFilterProvider).query,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SearchField(
    key: const ValueKey('timeline-search'),
    controller: _controller,
    onChanged: ref.read(timelineViewFilterProvider.notifier).search,
    decoration: compactSearchDecoration(hintText: 'Find a session'),
  );
}

/// Projects and machines to show, and what each mark means; on a phone,
/// the search too.
class _Filters extends ConsumerWidget {
  const _Filters({required this.machines, this.search = false});

  final List<String> machines;
  final bool search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final choices = ref.watch(timelineProjectChoicesProvider);
    final shown = ref.watch(timelineProjectFilterProvider);
    final projects = ref.read(timelineProjectFilterProvider.notifier);
    final view = ref.watch(timelineViewFilterProvider);
    final viewFilter = ref.read(timelineViewFilterProvider.notifier);
    final ids = [for (final c in choices) c.id];
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
      child: Text(
        text.toUpperCase(),
        style: Chrome.groupLabel.merge(
          TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (search) const _Search(),
          heading('Projects'),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              FilterChip(
                key: const ValueKey('timeline-project-all'),
                label: const Text('All projects'),
                selected: shown == null,
                onSelected: (_) => projects.showAll(),
              ),
              for (final choice in choices)
                FilterChip(
                  key: ValueKey('timeline-project-${choice.id}'),
                  label: Text(choice.name),
                  selected: shown?.contains(choice.id) ?? true,
                  onSelected: (_) => projects.toggle(choice.id, ids),
                ),
            ],
          ),
          if (machines.isNotEmpty) ...[
            heading('Machines'),
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                FilterChip(
                  key: const ValueKey('timeline-machine-all'),
                  label: const Text('All machines'),
                  selected: view.machines == null,
                  onSelected: (_) => viewFilter.allMachines(),
                ),
                for (final machine in machines)
                  FilterChip(
                    key: ValueKey('timeline-machine-$machine'),
                    label: Text(machine),
                    selected: view.machines?.contains(machine) ?? true,
                    onSelected: (_) =>
                        viewFilter.toggleMachine(machine, machines),
                  ),
              ],
            ),
          ],
          heading('What the marks mean'),
          const _Legend(padded: false),
        ],
      ),
    );
  }
}

/// What each mark means, so no state is told by colour alone.
class _Legend extends StatelessWidget {
  const _Legend({this.padded = true});

  final bool padded;

  @override
  Widget build(BuildContext context) {
    final palette = TimelinePalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    Widget item(String label, TimelineState state, {bool inferred = false}) =>
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: Insets.xl,
              height: Chrome.timelineSubBar,
              child: ExcludeSemantics(
                child: CustomPaint(
                  painter: TimelineSwatchPainter(
                    state: state,
                    palette: palette,
                    inferred: inferred,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Insets.xs),
            Text(label, style: style),
          ],
        );
    return Padding(
      padding: padded
          ? const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.xs)
          : EdgeInsets.zero,
      child: Wrap(
        spacing: Insets.lg,
        runSpacing: Insets.xs,
        children: [
          item('Working', TimelineState.working),
          item('Waiting on you', TimelineState.waiting),
          item('Ready', TimelineState.ready),
          item('Paused at a limit', TimelineState.paused),
          item(
            'Recovered or approximate',
            TimelineState.working,
            inferred: true,
          ),
        ],
      ),
    );
  }
}
