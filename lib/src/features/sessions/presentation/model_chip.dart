import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../agents/application/session_model_providers.dart';
import '../../agents/domain/agent_model_options.dart';
import '../application/session_launcher.dart';
import '../application/session_notice.dart';

/// One row of the model menu: a model to set for this session, or the default
/// to hand it back to.
///
/// A type of its own rather than a nullable `String` because `PopupMenuButton`
/// reads a null selection as a *dismissal* and never calls `onSelected` for it
/// — so "follow the default" written as a null value would have looked right
/// and done nothing.
@immutable
class ModelChoice {
  const ModelChoice(this.modelId);

  /// Follow the default — which today is the agent's own, since Karmashala
  /// stores no per-agent model preference. See `SessionLauncher.defaultModelFor`.
  static const followDefault = ModelChoice(null);

  final String? modelId;

  @override
  bool operator ==(Object other) =>
      other is ModelChoice && other.modelId == modelId;

  @override
  int get hashCode => modelId.hashCode;
}

/// Everything the chip draws, resolved from one session's model state.
///
/// A value rather than widget code, exactly like `UsageChipView`, so the
/// wording and the four states can be asserted without pumping a frame.
@immutable
class ModelChipView {
  const ModelChipView({
    required this.label,
    required this.qualifier,
    required this.tooltip,
    required this.alarming,
    required this.options,
    required this.selectedId,
    required this.inherited,
    required this.defaultDetail,
  });

  /// The words on the chip's face — a model's short label, or `default`.
  final String label;

  /// The small trailing qualifier, or null. `default` and `unlisted` are both
  /// things a reader must be able to see without hovering.
  final String? qualifier;

  final String tooltip;

  /// Whether the state is one to notice: an agent that cannot be told which
  /// model to run. Nothing else is tinted.
  final bool alarming;

  final List<AgentModelOption> options;

  /// The model this session will run on, or null when it follows the default.
  final String? selectedId;

  final bool inherited;

  /// The second line of the "follow the default" row: what the default
  /// resolves to *today*, because "follow the default" is not an answer to
  /// "what will this run on" — and that is the question the menu was opened
  /// with.
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
  );
  final current = state.modelId == null
      ? null
      : options.where((o) => o.model.id == state.modelId).firstOrNull;
  final tellable = state.support.isSupported;

  // "Following" rather than "inherited": inheriting sounds like something that
  // happened once, and the point of this state is that it is live.
  final origin = state.inherited
      ? 'No model is set for this session, so ${state.agentName} starts on '
            'whatever it is configured to use.'
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
    tooltip: [
      current?.model.label ?? state.modelId ?? 'Agent default',
      origin,
      rule,
    ].join('\n'),
    alarming: !tellable,
    options: options,
    selectedId: state.modelId,
    inherited: state.inherited,
    defaultDetail:
        'No model flag is passed, so ${state.agentName} starts on whatever '
        'it is configured to use.',
  );
}

/// The model this session runs on, and a menu of the models its agent can
/// actually be put on.
///
/// `PermissionModeChip`'s three rules hold here unchanged, and a fourth is
/// this control's own:
///
/// * **It shows the *effective* model**, resolved by `SessionLauncher` — the
///   same call the launcher makes, so the chip cannot drift from the command
///   line because there is no second resolution to drift from.
/// * **Only models the descriptor can express are selectable.** The rest are
///   listed, disabled, and say why: an agent that takes no model flag, and the
///   model a session is already on that this build's list has never heard of.
/// * **A session following the default says so, and can go back to it.** The
///   menu's first row is the way back, without which the first pick is
///   irreversible. It is a [ModelChoice] rather than a nullable `String`
///   because `PopupMenuButton` reads a *null* selection as a dismissal and
///   never calls `onSelected` for it — so "follow the default" written as a
///   null value would have looked right and done nothing.
/// * **Changing it may or may not touch the running process, and the chip says
///   which.** Claude Code and Antigravity take `/model <id>` in a session that
///   is sitting at its prompt; Codex's `/model` is a picker and takes no
///   argument, and no agent may be typed into mid-turn. So a pick is either
///   sent now or recorded for the next launch, every row says which before the
///   click, and the message afterwards says which happened. A control that
///   silently means two different things depending on which pane you are in is
///   the whole risk of doing this at all.
///
/// Either way the row is written, so a live switch and the next launch agree: a
/// user who moves to Opus and then restarts the session must not silently get
/// the old model back.
///
///
/// Values in, callbacks out, and nothing looked up here: [switchesNow] is a
/// callback rather than a value because whether a pick lands in the running
/// session depends on what the agent is doing *when the menu opens*, and a
/// value computed at build time would be a promise made a minute ago.
class ModelChip extends StatelessWidget {
  const ModelChip({
    required this.view,
    required this.switchesNow,
    required this.onSelected,
    this.maxLabelWidth = 120,
    super.key,
  });

  /// Builds of the chip, counted so a cost test can prove a model change
  /// repaints this and nothing else around it.
  @visibleForTesting
  static int debugBuildCount = 0;

  final ModelChipView view;

  /// Whether a pick made this instant would reach the session running now,
  /// asked as the menu opens. See
  /// [SessionLauncher.liveModelSwitchBlockerFor].
  final bool Function() switchesNow;

  final ValueChanged<ModelChoice> onSelected;

  /// How much room the model's name may take. The status bar is tighter than
  /// the composer, and at 720px this is the difference between a row that
  /// yields and a row that overflows.
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    ModelChip.debugBuildCount++;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = view.alarming ? scheme.error : scheme.onSurfaceVariant;

    return PopupMenuButton<ModelChoice>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: onSelected,
      itemBuilder: (context) {
        // Asked once, as the menu opens, and shared by every row: whether a
        // pick lands in the running session is a property of the agent and the
        // moment, not of which model was picked.
        final live = switchesNow();
        return [
          // First, and its own row: handing the session back to the default is
          // where every session starts and the only way back from a pick.
          DesktopMenuDetailItem<ModelChoice>(
            value: ModelChoice.followDefault,
            selected: view.selectedId == null,
            label: 'Let the agent choose',
            badge: 'next launch',
            detail: view.defaultDetail,
          ),
          const DesktopMenuDivider(),
          for (final option in view.options)
            DesktopMenuDetailItem<ModelChoice>(
              value: ModelChoice(option.model.id),
              enabled: option.isSelectable,
              selected: option.model.id == view.selectedId,
              label: option.model.label,
              badge: option.isSelectable
                  ? (live ? 'now' : 'next launch')
                  : option.fitLabel,
              badgeColor: option.isSelectable
                  ? (live ? scheme.tertiary : scheme.onSurfaceVariant)
                  : scheme.error,
              detail: option.summary,
            ),
        ];
      },
      child: Tooltip(
        message: view.tooltip,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                view.alarming ? AppIcons.warningCircle : AppIcons.robot,
                size: Chrome.iconSmall,
                color: foreground,
              ),
              const SizedBox(width: Insets.xs),
              // Capped, ellipsised **and** flexible: `Gemini 3.7 Flash
              // (Medium)` is a real model name, and the status bar has no room
              // to spare at 720px with Windows' largest text step. The cap
              // stops it dominating a wide window; the `Flexible` is what makes
              // the name — and not the row — the thing that gives way when
              // there is no room at all.
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxLabelWidth),
                  child: Text(
                    view.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ),
              if (view.qualifier != null) ...[
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    '· ${view.qualifier}',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
              // A disclosure caret, deliberately a step under the chip's own
              // glyph — the same 11 the permission chips and the picker draw.
              Icon(AppIcons.caretDown, size: 11, color: foreground),
            ],
          ),
        ),
      ),
    );
  }
}

/// [ModelChip] bound to one session. The composer's chip.
class SessionModelChip extends ConsumerWidget {
  const SessionModelChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _buildModelChip(context, ref, ref.watch(sessionModelProvider(sessionId)));
}

/// [ModelChip] following the focused session. The status bar's chip.
///
/// `const` where it is placed, so a rebuild of the row cannot rebuild the chip
/// and a model change cannot rebuild the row — the subscription is the chip's
/// own, exactly as `UsageChip`'s is.
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
    switchesNow: () =>
        launcher.liveModelSwitchBlockerFor(state.sessionId) == null,
    onSelected: (choice) => _apply(ref, launcher, state, choice),
  );
}

void _apply(
  WidgetRef ref,
  SessionLauncher launcher,
  SessionModelState state,
  ModelChoice choice,
) {
  // Into the session's own bar, for the reason `PermissionModeChip` gives: every
  // sentence below is about one session, and the two chips sit in the same row
  // — a message from one arriving across the bottom of the window and a message
  // from the other arriving beside the chip would be the same event reported two
  // different ways.
  final notices = ref.read(sessionNoticesProvider.notifier);
  final outcome = launcher.setModel(state.sessionId, choice.modelId);
  final what = choice.modelId == null
      ? '${state.agentName} will choose its own model'
      : (state.support.modelFor(choice.modelId)?.label ?? choice.modelId!);
  // Only ever one of two sentences, and never a third that could be read as
  // either. The deferral says *why*, because "the agent is mid-turn" is a wait
  // a moment and "this CLI takes its model from the command line" is a never.
  final message = outcome.switchedNow
      ? '$what — switched now: "${outcome.command}" was sent to the session.'
      : switch (outcome.deferral) {
          ModelDeferral.busy =>
            '$what — applies on the next launch. ${state.agentName} is '
                'mid-turn, so nothing was typed into the running session.',
          ModelDeferral.noCommand =>
            '$what — applies on the next launch. ${state.agentName} takes its '
                'model from the command line, so the session running now is '
                'unchanged.',
          ModelDeferral.noModel =>
            '$what — applies on the next launch. There is no model to switch '
                'to, so the session running now is unchanged.',
          _ => '$what — applies when this session next runs.',
        };
  notices.post(state.sessionId, SessionNotice(message: message));
}
