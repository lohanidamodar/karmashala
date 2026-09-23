import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../agents/application/session_model_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../agents/presentation/model_picker.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/session_launcher.dart';
import '../application/session_notice.dart';

/// Everything the chip draws, resolved from one session's model state. A value
/// rather than widget code, so the four states can be asserted without a frame.
@immutable
class ModelChipView {
  const ModelChipView({
    required this.label,
    required this.qualifier,
    required this.tooltip,
    required this.origin,
    required this.alarming,
    required this.options,
    required this.selectedId,
    required this.inherited,
    required this.defaultModelId,
    required this.defaultDetail,
  });

  /// The words on the chip's face — a model's short label, or `default`.
  final String label;

  /// The small trailing qualifier, or null. `default` and `unlisted` are both
  /// things a reader must be able to see without hovering.
  final String? qualifier;

  final String tooltip;

  /// Where the model came from, as a sentence. Its own field so
  /// [SessionModelMark] can say the same thing rather than a second wording.
  final String origin;

  /// Whether the state is one to notice: an agent that cannot be told which
  /// model to run. Nothing else is tinted.
  final bool alarming;

  final List<AgentModelOption> options;

  /// The model this session will run on, or null when it follows the default.
  final String? selectedId;

  final bool inherited;

  /// What the per-agent default in Settings names *today*, or null for "let the
  /// agent choose". Null is why the way-back row cannot promise a live switch.
  final String? defaultModelId;

  /// The second line of the "follow the Settings default" row: "follow the
  /// default" is not an answer to "what will this run on".
  final String defaultDetail;

  /// Whether there is anything to draw at all. An agent whose models nobody has
  /// recorded gets no chip, rather than an empty menu.
  bool get isEmpty => options.isEmpty;
}

/// What the chip should say about [state].
ModelChipView modelChipViewFor(SessionModelState state) {
  final options = modelOptionsFor(
    state.descriptor,
    current: state.modelId,
    agentName: state.agentName,
    support: state.support,
  );
  final current = state.modelId == null
      ? null
      : options.where((o) => o.model.id == state.modelId).firstOrNull;
  final tellable = state.support.isSupported;
  // The Settings default's own name, so every sentence about "the default" can
  // say what it is instead of making the reader go and look.
  final defaultLabel = state.defaultModelId == null
      ? null
      : (state.support.modelFor(state.defaultModelId)?.label ??
            state.defaultModelId!);

  // "Following" rather than "inherited": inheriting sounds like something that
  // happened once, and the point of this state is that it is live.
  final origin = state.inherited
      ? defaultLabel == null
            ? 'No model is set for this session, and Settings leaves the '
                  'choice to ${state.agentName}, so it starts on whatever it '
                  'is configured to use.'
            : 'No model is set for this session, so it follows the Settings '
                  'default for ${state.agentName} ($defaultLabel) and moves '
                  'when that setting moves.'
      : 'Set for this session, and it stays set across a relaunch.';
  final rule = tellable
      ? state.support.switchesLive
            ? 'Picking one switches the session running now when '
                  '${state.agentName} is at its prompt, and otherwise applies '
                  'on the next launch.'
            : '${state.agentName} takes its model from the command line, so a '
                  'pick applies on the next launch.'
      : '${state.agentName} takes no model flag, so Karmashala cannot change '
            'this.';

  return ModelChipView(
    label: current?.model.label ?? (state.modelId ?? 'default'),
    qualifier: state.modelId == null
        ? null
        : (current?.fitLabel ?? (state.inherited ? 'default' : null)),
    origin: origin,
    tooltip: [
      current?.model.label ?? state.modelId ?? 'Agent default',
      origin,
      rule,
    ].join('\n'),
    alarming: !tellable,
    options: options,
    selectedId: state.modelId,
    inherited: state.inherited,
    defaultModelId: state.defaultModelId,
    defaultDetail: defaultLabel == null
        ? 'Settings leaves the choice to ${state.agentName}, so no model flag '
              'is passed and it starts on whatever it is configured to use.'
        : 'Currently $defaultLabel for ${state.agentName}. Changing that '
              'setting changes this session too.',
  );
}

/// The model this session runs on, and a menu of the models its agent can be
/// put on. The way-back row is a [ModelChoice]: null reads as a *dismissal*.
class ModelChip extends StatelessWidget {
  const ModelChip({
    required this.view,
    required this.whenPicked,
    required this.onSelected,
    this.maxLabelWidth = 120,
    super.key,
  });

  /// Builds of the chip, counted so a cost test can prove a model change
  /// repaints this and nothing else around it.
  @visibleForTesting
  static int debugBuildCount = 0;

  final ModelChipView view;

  /// When a pick made this instant reaches the session — `now`, `after this
  /// turn` or `next launch` — asked as the menu opens. See
  /// [SessionLauncher.liveModelSwitchBlockerFor].
  final String Function() whenPicked;

  final ValueChanged<ModelChoice> onSelected;

  /// How much room the model's name may take. At 720px this is the difference
  /// between a row that yields and a row that overflows.
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    ModelChip.debugBuildCount++;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PopupMenuButton<ModelChoice>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: onSelected,
      itemBuilder: (context) {
        // Asked once as the menu opens and shared by every row: whether a pick
        // lands is a property of the agent and the moment, not of the model.
        final lands = whenPicked();
        final live = lands == 'now';
        return [
          // First, and its own row: handing the session back to the default is
          // where every session starts and the only way back from a pick.
          DesktopMenuDetailItem<ModelChoice>(
            value: ModelChoice.followDefault,
            selected: view.inherited,
            label: 'Follow the Settings default',
            // A default that names no model has nothing to switch *to* — see
            // [ModelDeferral.noModel].
            badge: view.defaultModelId != null ? lands : 'next launch',
            detail: view.defaultDetail,
          ),
          const DesktopMenuDivider(),
          for (final option in view.options)
            DesktopMenuDetailItem<ModelChoice>(
              value: ModelChoice(option.model.id),
              enabled: option.isSelectable,
              // Never both: a session following the default resolves to a
              // model, and ticking it too would read as a choice it made.
              selected: !view.inherited && option.model.id == view.selectedId,
              label: option.model.label,
              badge: option.isSelectable ? lands : option.fitLabel,
              badgeColor: option.isSelectable
                  ? (live ? scheme.tertiary : scheme.onSurfaceVariant)
                  : scheme.error,
              detail: option.summary,
            ),
        ];
      },
      child: Tooltip(
        message: view.tooltip,
        // Capped, ellipsised **and** flexible: the cap stops a long name
        // dominating a wide window, the face yields the name first.
        child: PickerFace(
          icon: view.alarming ? AppIcons.warningCircle : AppIcons.robot,
          label: view.label,
          qualifiers: [?view.qualifier],
          alarming: view.alarming,
          maxLabelWidth: maxLabelWidth,
        ),
      ),
    );
  }
}

/// [ModelChip] bound to one session. The composer's chip, and the terminal
/// bar's.
class SessionModelChip extends ConsumerWidget {
  const SessionModelChip({
    required this.sessionId,
    this.maxLabelWidth = 120,
    super.key,
  });

  final String sessionId;

  /// How much of the model's name to show before ellipsising. The terminal's
  /// bar asks less: a pixel here can push `Commit` onto a line of its own.
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _buildModelChip(
    context,
    ref,
    ref.watch(sessionModelProvider(sessionId)),
    maxLabelWidth: maxLabelWidth,
  );
}

/// The model a session is **set to** run on, drawn as a fact, not a control. It
/// will not claim the CLI is running it — nothing reads a model back out.
class SessionModelMark extends ConsumerWidget {
  const SessionModelMark({
    required this.sessionId,
    this.maxWidth = 140,
    super.key,
  });

  /// Builds of the mark, counted so a cost test can prove that an unrelated
  /// session signal does not reach it and a model change does.
  @visibleForTesting
  static int debugBuildCount = 0;

  final String sessionId;

  /// How much room the model's name may take before it ellipsises. The line
  /// this sits in wraps rather than shrinks, so an uncapped name costs a run.
  final double maxWidth;

  /// Whether [state] names a model this mark will draw. Static because it is
  /// the *host's* test too: a zero-sized child still takes its `spacing`.
  static bool namesAModel(SessionModelState? state) =>
      state != null && state.modelId != null && state.support.isSupported;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    SessionModelMark.debugBuildCount++;
    final state = ref.watch(sessionModelProvider(sessionId));
    if (!namesAModel(state)) return const SizedBox.shrink();
    final view = modelChipViewFor(state!);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: [view.label, view.origin, _modelMarkLimit(state)].join('\n'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.robot, size: Chrome.iconSmall, color: muted),
          const SizedBox(width: Insets.xs),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Text(
              view.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one thing the mark will not vouch for, worded for the agent. Two
/// sentences: a Codex user told the first would hunt for a live switch.
String _modelMarkLimit(SessionModelState state) => state.support.switchesLive
    ? '${state.agentName} is never asked what it is running, so this is what '
          'the session is set to. A /model typed into the terminal, or a '
          'change recorded while the agent was mid-turn, leaves this ahead of '
          'the process.'
    : '${state.agentName} takes its model at launch and is never asked what it '
          'is running, so this is what the next launch uses — a change made '
          'since this session started is not true of the process now.';

/// [ModelChip] following the focused session. `const` where it is placed, so a
/// row rebuild cannot rebuild the chip, nor a model change the row.
class FocusedModelChip extends ConsumerWidget {
  const FocusedModelChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _buildModelChip(
    context,
    ref,
    ref.watch(focusedSessionModelProvider),
    maxLabelWidth: 72,
  );
}

/// The shared body of the two placements: a state in, a chip or nothing out.
Widget _buildModelChip(
  BuildContext context,
  WidgetRef ref,
  SessionModelState? state, {
  double maxLabelWidth = 120,
}) {
  if (state == null) return const SizedBox.shrink();
  final view = modelChipViewFor(state);
  if (view.isEmpty) return const SizedBox.shrink();
  final launcher = ref.read(sessionLauncherProvider);
  return ModelChip(
    view: view,
    maxLabelWidth: maxLabelWidth,
    whenPicked: () =>
        switch (launcher.liveModelSwitchBlockerFor(state.sessionId)) {
          null => 'now',
          ModelDeferral.busy => 'after this turn',
          _ => 'next launch',
        },
    onSelected: (choice) => _apply(ref, launcher, state, choice),
  );
}

void _apply(
  WidgetRef ref,
  SessionLauncher launcher,
  SessionModelState state,
  ModelChoice choice,
) {
  // Into the session's own bar: every sentence below is about one session, and
  // a snackbar beside a chip would be one event told two ways.
  final notices = ref.read(sessionNoticesProvider.notifier);
  final outcome = launcher.setModel(state.sessionId, choice.modelId);
  String label(String id) => state.support.modelFor(id)?.label ?? id;
  final target = choice.modelId ?? state.defaultModelId;
  final what = choice.modelId != null
      ? label(choice.modelId!)
      : target == null
      ? '${state.agentName} will choose its own model'
      : 'Following the Settings default (${label(target)})';
  // Only ever one of two sentences. The deferral says *why*: "the agent is
  // mid-turn" is a wait a moment, "takes its model at launch" is a never.
  final message = outcome.switchedNow
      ? '$what — switched now: "${outcome.command}" was sent to the session.'
      : switch (outcome.deferral) {
          ModelDeferral.busy =>
            '$what — switches when ${state.agentName} finishes this turn. '
                'Nothing is typed into the session while it is working.',
          ModelDeferral.noCommand =>
            '$what — applies on the next launch. ${state.agentName} takes its '
                'model from the command line, so the session running now is '
                'unchanged.',
          ModelDeferral.openedPicker =>
            '$what — ${state.agentName} opened its own model picker in the '
                'session; choose it there to switch now. It is also recorded for '
                'the next launch.',
          ModelDeferral.noModel =>
            '$what — applies on the next launch. There is no model to switch '
                'to, so the session running now is unchanged.',
          _ => '$what — applies when this session next runs.',
        };
  notices.post(state.sessionId, SessionNotice(message: message));
}
