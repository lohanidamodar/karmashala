import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../../../app/shell/workbench_tabs.dart' show openSettingsTab;
import '../../../../core/capabilities/capabilities.dart';
import '../../../../core/util/failure_words.dart';
import '../../../projects/application/projects_controller.dart';
import '../../../sessions/application/session_ui_providers.dart';
import '../../../settings/presentation/settings_catalog.dart';
import '../application/timeline_controller.dart';
import '../domain/timeline_model.dart';
import 'timeline_chart.dart';
import 'timeline_painters.dart';
import 'timeline_phone_list.dart';

/// The projects the timeline may show as rows, by id and name.
final timelineProjectChoicesProvider =
    Provider<List<({String id, String name})>>((ref) {
      return [
        for (final project in ref.watch(projectsControllerProvider))
          (id: project.id, name: project.name),
      ];
    });

/// Narrower than this, the timeline is a list of the range's sessions.
const double kTimelinePhoneWidth = 600;

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

  DateTime _clock() => (widget.clock ?? DateTime.now)().toUtc();

  @override
  void initState() {
    super.initState();
    _now = _clock();
    // Live bars grow at the right edge; a minute is as fine as a bar reads.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_model.projects.any((p) => p.sessions.any((s) => s.live))) {
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

  @override
  Widget build(BuildContext context) {
    final range = ref.watch(timelineRangeProvider);
    final filter = ref.watch(timelineProjectFilterProvider);
    final query = TimelineQuery(
      from: range.from,
      to: range.to,
      projectIds: filter,
    );
    final entries = ref.watch(timelineEntriesProvider(query));
    return LayoutBuilder(
      builder: (context, constraints) {
        final phone = constraints.maxWidth < kTimelinePhoneWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(range: range, phone: phone, zoom: _zoom),
            if (!phone) const _Legend(),
            const Divider(height: Insets.hair),
            Expanded(
              child: switch (entries) {
                AsyncData(:final value) => _body(
                  _modelFor(value, range),
                  phone: phone,
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

  Widget _body(TimelineModel model, {required bool phone}) {
    if (model.sessionCount == 0) {
      return const _Message(
        key: ValueKey('timeline-empty'),
        text:
            'Nothing recorded in this range. Sessions deleted before the '
            'timeline existed cannot be shown.',
      );
    }
    return phone
        ? TimelinePhoneList(model: model, now: _now, onOpen: _open)
        : TimelineChart(
            model: model,
            now: _now,
            onOpen: _open,
            controller: _zoom,
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

String _rangeLabel(TimelineRange range) {
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
  String day(DateTime d) => '${d.day} ${months[d.month - 1]} ${d.year}';
  if (range.isOneDay) return day(range.from);
  final last = DateTime(range.to.year, range.to.month, range.to.day - 1);
  return '${day(range.from)} – ${day(last)}';
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.range,
    required this.phone,
    required this.zoom,
  });

  final TimelineRange range;
  final bool phone;
  final TimelineZoomController zoom;

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
    final step = range.isOneDay ? 'day' : 'range';
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
          IconButton(
            key: const ValueKey('timeline-previous'),
            tooltip: 'Previous $step',
            icon: const Icon(AppIcons.caretLeft),
            onPressed: controller.previous,
          ),
          TextButton.icon(
            key: const ValueKey('timeline-range'),
            icon: const Icon(AppIcons.clock),
            label: Text(_rangeLabel(range)),
            onPressed: () => _pickRange(context, ref),
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
          const _ProjectFilter(),
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
            TextButton(onPressed: zoom.fit, child: const Text('Fit')),
          ],
        ],
      ),
    );
  }
}

class _ProjectFilter extends ConsumerWidget {
  const _ProjectFilter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choices = ref.watch(timelineProjectChoicesProvider);
    final shown = ref.watch(timelineProjectFilterProvider);
    final filter = ref.read(timelineProjectFilterProvider.notifier);
    final ids = [for (final c in choices) c.id];
    final label = shown == null
        ? 'All projects'
        : shown.length == 1
        ? choices.where((c) => shown.contains(c.id)).firstOrNull?.name ??
              '1 project'
        : '${shown.length} projects';
    return MenuAnchor(
      menuChildren: [
        CheckboxMenuButton(
          value: shown == null,
          onChanged: (_) => filter.showAll(),
          child: const Text('All projects'),
        ),
        for (final choice in choices)
          CheckboxMenuButton(
            key: ValueKey('timeline-project-${choice.id}'),
            value: shown?.contains(choice.id) ?? true,
            closeOnActivate: false,
            onChanged: (_) => filter.toggle(choice.id, ids),
            child: Text(choice.name),
          ),
      ],
      builder: (context, menu, _) => TextButton.icon(
        key: const ValueKey('timeline-projects'),
        icon: const Icon(AppIcons.funnel),
        label: Text(label),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

/// What each look means, so no state is told by colour alone.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final palette = TimelinePalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    Widget item(String label, TimelineState state, {bool inferred = false}) {
      final now = DateTime.utc(2000);
      final sample = TimelineSession(
        id: label,
        title: label,
        projectId: '',
        projectName: '',
        start: now,
        end: now.add(const Duration(hours: 1)),
        live: false,
        startOnly: false,
        deleted: false,
        backfilled: inferred,
        spans: [
          TimelineSpan(
            state: state,
            from: now,
            to: now.add(const Duration(hours: 1)),
            approximate: inferred,
          ),
        ],
        ticks: const [],
        markers: const [],
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: Insets.xl + Insets.xs,
            height: Chrome.iconAction,
            child: ExcludeSemantics(
              child: CustomPaint(
                painter: TimelineLanePainter(
                  session: sample,
                  viewport: TimelineViewport(
                    start: sample.start,
                    end: sample.end,
                  ),
                  palette: palette,
                  now: now,
                  compact: true,
                  labels: false,
                ),
              ),
            ),
          ),
          const SizedBox(width: Insets.xs),
          Text(label, style: style),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.xs),
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
