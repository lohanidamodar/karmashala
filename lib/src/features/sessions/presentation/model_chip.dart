import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../agents/application/session_model_providers.dart';
import '../../agents/domain/agent_model_options.dart';
import '../../agents/presentation/model_picker.dart';
import '../application/session_launcher.dart';
import '../application/session_notice.dart';

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

  /// Where the model came from, as a sentence: a choice made for this session,
  /// or the Settings default followed live. Carried as its own field rather
  /// than only baked into [tooltip] so [SessionModelMark] can say the same
  /// thing — one wording, so the control and the fact beside it cannot describe
  /// the same session's model differently.
  final String origin;

  /// Whether the state is one to notice: an agent that cannot be told which
  /// model to run. Nothing else is tinted.
  final bool alarming;

  final List<AgentModelOption> options;

  /// The model this session will run on, or null when it follows the default.
  final String? selectedId;

  final bool inherited;

  /// What the per-agent default in Settings names *today*, or null for "let the
  /// agent choose". Null is why the way-back row cannot promise a live switch:
  /// there is nothing to switch to.
  final String? defaultModelId;

  /// The second line of the "follow the Settings default" row: what that
  /// default resolves to *today*, because "follow the default" is not an answer
  /// to "what will this run on" — and that is the question the menu was opened
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
///   default is the per-agent one in **Settings**, followed live — a session
///   that never chose moves when that setting moves, and a session that chose
///   does not. The menu's first row is the way back, without which the first
///   pick is irreversible. It is a [ModelChoice] rather than a nullable
///   `String` because `PopupMenuButton` reads a *null* selection as a dismissal
///   and never calls `onSelected` for it — so "follow the default" written as a
///   null value would have looked right and done nothing.
///   The Settings default may itself name no model, and that stays a legitimate
///   answer rather than a gap: no `--model` is passed and the agent chooses.
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
            selected: view.inherited,
            label: 'Follow the Settings default',
            // A default that names no model has nothing to switch *to*, so this
            // row cannot promise `now` however idle the agent is — see
            // [ModelDeferral.noModel].
            badge: view.defaultModelId != null && live ? 'now' : 'next launch',
            detail: view.defaultDetail,
          ),
          const DesktopMenuDivider(),
          for (final option in view.options)
            DesktopMenuDetailItem<ModelChoice>(
              value: ModelChoice(option.model.id),
              enabled: option.isSelectable,
              // Never both: a session that follows the default resolves to a
              // model, and ticking that model as well would read as a choice
              // this session made.
              selected: !view.inherited && option.model.id == view.selectedId,
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
  /// bar asks for less than the composer does: it shares a row with the
  /// delivery actions, and those wrap to a second run rather than shrink — so
  /// every pixel this takes is one that can push `Commit` onto a line of its
  /// own.
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _buildModelChip(
    context,
    ref,
    ref.watch(sessionModelProvider(sessionId)),
    maxLabelWidth: maxLabelWidth,
  );
}

/// The model a session is **set to** run on, drawn as a fact rather than as a
/// control.
///
/// `SessionVerdictMark`'s neighbour in the delivery state line, and the reason
/// there are two model presentations rather than one. [SessionModelChip] is the
/// thing that *changes* the model: bordered, pressable, a caret, capped at 72px
/// on the session bar and dropped altogether when that bar is under ~820px,
/// because a control has to compete for room with the delivery actions. This is
/// only the name, in the quiet line of facts above them, at every width. Both
/// take their words from [modelChipViewFor], so the two can never name the same
/// session's model differently.
///
/// **What it claims.** What Karmashala has this session set to — the id the
/// next launch puts on the command line, and the id a live `/model` was sent
/// for.
///
/// **What it refuses to claim.** That this is what the CLI is running now.
/// Nothing in the app reads a model back out of an agent, and two ordinary
/// things put the record ahead of the process:
///
/// * a `/model` typed into the pane by the user or by the agent, which nothing
///   tells us about; and
/// * a change recorded while the agent could not be told — mid-turn, or an
///   agent like Codex whose `/model` opens a picker and takes no argument, so a
///   pick only ever applies at the next launch.
///
/// Neither is detectable without matching text out of the terminal, which is
/// the most fragile thing in this app and not worth a status line. So the mark
/// says what it is instead of guessing: the tooltip names the limit that
/// applies to *this* agent, and the face carries no word — no "now", no
/// "running", no "active" — that would promise liveness.
///
/// It therefore draws **only a model we actually named**. A session on an
/// agent's own default (no id anywhere, no `--model` passed) draws nothing, and
/// so does an agent that takes no model flag at all. In both, the honest answer
/// is that we do not know what it is running, and `default` sitting in a line
/// of facts between a stage and a branch would read as one.
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
  /// this sits in wraps rather than shrinks, so an uncapped
  /// `Gemini 3.7 Flash (Medium)` next to a long branch name costs the bar a
  /// whole extra run.
  final double maxWidth;

  /// Whether [state] names a model this mark is willing to draw.
  ///
  /// Static, because it is the *host's* test as much as the mark's: the state
  /// line asks it to decide whether to put a mark in its `Wrap` at all. A
  /// zero-sized child there would still take a `spacing` on each side and leave
  /// a double gap exactly where the model was not — and a session with no model
  /// named is the ordinary case, not the rare one.
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
          const SizedBox(width: 4),
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

/// The one thing the mark will not vouch for, worded for the agent it is about.
///
/// Two sentences rather than one hedge, for the reason `ModelDeferral` gives
/// about its four values: "a `/model` you typed is not read back" and "this CLI
/// only takes its model at launch" are different limits, and telling a Codex
/// user the first would send them looking for a live switch that does not
/// exist.
String _modelMarkLimit(SessionModelState state) => state.support.switchesLive
    ? '${state.agentName} is never asked what it is running, so this is what '
          'the session is set to. A /model typed into the terminal, or a '
          'change recorded while the agent was mid-turn, leaves this ahead of '
          'the process.'
    : '${state.agentName} takes its model at launch and is never asked what it '
          'is running, so this is what the next launch uses — a change made '
          'since this session started is not true of the process now.';

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
  String label(String id) => state.support.modelFor(id)?.label ?? id;
  final target = choice.modelId ?? state.defaultModelId;
  final what = choice.modelId != null
      ? label(choice.modelId!)
      : target == null
      ? '${state.agentName} will choose its own model'
      : 'Following the Settings default (${label(target)})';
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
