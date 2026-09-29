import 'package:flutter/material.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/presentation/permission_mode_picker.dart';
import '../application/session_handoff_service.dart';
import 'tool_activity_row.dart' show kExpandedOutputMaxHeight;

// The parts of ContinueWithDialog, each drawing values it is handed. The
// dialog owns every decision; these only say it.

/// What pressing the primary button will do, in one sentence — or null when
/// it cannot be done, and [continueBlockedReason] says why instead.
String? continueSummary({
  required bool fork,
  required SessionForkPlan plan,
  required HandoffTarget? target,
  required String sourceName,
  required String? sessionTitle,
  required String? checkoutName,
  required bool newWorktree,
}) {
  final subject = sessionTitle == null ? 'this session' : '“$sessionTitle”';
  final where = newWorktree
      ? 'in a new worktree${checkoutName == null ? '' : ' of $checkoutName'}'
      : 'in ${checkoutName ?? 'the same checkout'}, same folder and '
            'branch';
  if (fork) {
    return switch (plan.kind) {
      SessionForkKind.native =>
        'Forks $subject with its whole conversation into a new $sourceName '
            'session $where. This session is left as it is.',
      SessionForkKind.handoff =>
        'Starts a new $sourceName session $where from a written recap of '
            '$subject. This session is left as it is.',
      SessionForkKind.refused => null,
    };
  }
  if (target == null || !target.canReceive) return null;
  return 'Starts a new ${target.agentName} session $where, briefed with a '
      'written recap of $subject. This session keeps running.';
}

/// Why the primary button is disabled, or null when it is not.
String? continueBlockedReason({
  required bool fork,
  required SessionForkPlan plan,
  required HandoffTarget? target,
  required String sourceName,
  required bool hasInstruction,
}) {
  if (fork && plan.isRefused) return '$sourceName cannot be forked here.';
  if (!fork && (target == null || !target.canReceive)) {
    return 'No agent here can take this session.';
  }
  if (!hasInstruction) return 'Write what the next agent should do.';
  return null;
}

/// The agent picker, with each target's permission consequence beside it. One
/// that cannot receive the packet is **listed and disabled**, never hidden.
class ContinueTargetPicker extends StatelessWidget {
  const ContinueTargetPicker({
    required this.targets,
    required this.selected,
    required this.permissionFor,
    required this.onChanged,
    super.key,
  });

  final List<HandoffTarget> targets;
  final HandoffTarget? selected;

  /// Each row's permission sentence, resolved against the mode picked so far —
  /// the session's alone would answer for a mode already changed.
  final ContinuationPermission Function(HandoffTarget) permissionFor;

  final ValueChanged<HandoffTarget> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (targets.isEmpty) {
      return ContinueCallout(
        icon: AppIcons.warningCircle,
        colour: theme.colorScheme.error,
        text:
            'No agent is installed in this session\'s environment. Run '
            '"Discover agents" in Settings.',
      );
    }
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return RadioGroup<String>(
      groupValue: selected?.installation.id,
      onChanged: (id) {
        for (final target in targets) {
          if (target.installation.id == id && target.canReceive) {
            onChanged(target);
          }
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final target in targets)
            RadioListTile<String>(
              value: target.installation.id,
              enabled: target.canReceive,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Row(
                children: [
                  Flexible(child: Text(target.agentName)),
                  if (target.isSameAgent) ...[
                    const SizedBox(width: Insets.sm),
                    Flexible(
                      child: Text(
                        'same agent, fresh conversation',
                        style: muted,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: _TargetNote(
                target: target,
                permission: permissionFor(target),
              ),
            ),
        ],
      ),
    );
  }
}

/// A target row's second line: why it cannot receive, or what its mode
/// becomes. A warning glyph as well as the colour, so it is not colour alone.
class _TargetNote extends StatelessWidget {
  const _TargetNote({required this.target, required this.permission});

  final HandoffTarget target;
  final ContinuationPermission permission;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = !target.canReceive || !permission.carried.enforced;
    final colour = warn
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (warn) ...[
          Padding(
            padding: const EdgeInsets.only(top: Insets.hair),
            child: Icon(
              AppIcons.warningCircle,
              size: Chrome.iconSmall,
              color: colour,
            ),
          ),
          const SizedBox(width: Insets.xs),
        ],
        Expanded(
          child: Text(
            target.refusal ?? permission.carried.summary,
            style: theme.textTheme.labelSmall?.copyWith(color: colour),
          ),
        ),
      ],
    );
  }
}

/// The mode the next session will run under, and where that answer came from.
/// It sits under the agent because the modes on offer are that agent's.
class ContinuePermissionRow extends StatelessWidget {
  const ContinuePermissionRow({
    required this.permission,
    required this.descriptor,
    required this.followsDefault,
    required this.agentName,
    required this.onChanged,
    super.key,
  });

  final ContinuationPermission permission;

  /// The target agent, so the picker can draw *its* axes. Re-run on every agent
  /// change, so one CLI's pick is never shown against another's vocabulary.
  final AgentDescriptor? descriptor;

  /// Whether the mode on offer is the Settings default rather than anything
  /// this session or this user decided. See [HandoffTarget.followsDefault].
  final bool followsDefault;

  final String agentName;

  final ValueChanged<PermissionSelection> onChanged;

  /// Where this mode came from in the one case [ContinuationPermission] cannot
  /// know: nobody chose it, so "carried from this session" would be wrong.
  String get _explanation => followsDefault && !permission.wasChosen
      ? 'Following the $agentName default in Settings, as this session does. '
            'It changes when that setting does. ${permission.carried.summary}'
      : permission.explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enforced = permission.carried.enforced;
    final colour = enforced
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('Runs under', style: theme.textTheme.bodySmall),
            const SizedBox(width: Insets.sm),
            // Flexible: Codex's label is a pair ("Workspace · On request"),
            // which is wider than three short words.
            Flexible(
              child: PermissionModePicker(
                descriptor: descriptor,
                selection: permission.selection,
                onChanged: onChanged,
                agentName: agentName,
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!enforced) ...[
              Icon(
                AppIcons.warningCircle,
                size: Chrome.iconSmall,
                color: colour,
              ),
              const SizedBox(width: Insets.xs),
            ],
            Expanded(
              child: Text(
                _explanation,
                style: theme.textTheme.labelSmall?.copyWith(color: colour),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A glyph and a paragraph on the raised tone: what the CLI will really do,
/// or why nothing can be done. `**bold**` in [text] is drawn bold, as the
/// fork plan's explanations are written that way.
class ContinueCallout extends StatelessWidget {
  const ContinueCallout({
    required this.icon,
    required this.colour,
    required this.text,
    super.key,
  });

  final IconData icon;
  final Color colour;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final parts = text.split('**');
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).raised,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: Chrome.iconAction, color: colour),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < parts.length; i++)
                    TextSpan(
                      text: parts[i],
                      style: i.isOdd
                          ? const TextStyle(fontWeight: FontWeight.w600)
                          : null,
                    ),
                ],
              ),
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// What forking will really do, in the CLI's terms, before it happens.
class ForkPlanNote extends StatelessWidget {
  const ForkPlanNote({required this.plan, super.key});

  final SessionForkPlan plan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, colour) = switch (plan.kind) {
      SessionForkKind.native => (AppIcons.checkCircle, scheme.primary),
      SessionForkKind.handoff => (AppIcons.info, scheme.onSurfaceVariant),
      SessionForkKind.refused => (AppIcons.warningCircle, scheme.error),
    };
    return ContinueCallout(icon: icon, colour: colour, text: plan.explanation);
  }
}

/// A folded group of the options most continuations leave alone. It opens by
/// itself when one of them is set, so a choice is never hidden.
class MoreOptions extends StatelessWidget {
  const MoreOptions({
    required this.open,
    required this.onToggle,
    required this.children,
    this.setCount = 0,
    super.key,
  });

  final bool open;
  final VoidCallback? onToggle;
  final List<Widget> children;

  /// How many of the folded options are set, said on the closed row.
  final int setCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: open,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(Radii.sm),
            hoverColor: SurfaceTones.of(context).hover,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Chrome.menuRow),
              child: Row(
                children: [
                  Icon(
                    open ? AppIcons.caretDown : AppIcons.caretRight,
                    size: Chrome.iconSmall,
                    color: muted,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text('More options', style: theme.textTheme.bodySmall),
                  if (!open && setCount > 0) ...[
                    const SizedBox(width: Insets.sm),
                    Text(
                      '$setCount set',
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: Chrome.treeGutter,
              top: Insets.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
      ],
    );
  }
}

/// "What happens": the one-sentence account of the launch, or why there is
/// none, on the raised tone just above the buttons it describes.
class ContinueSummary extends StatelessWidget {
  const ContinueSummary({
    required this.summary,
    required this.blockedReason,
    super.key,
  });

  final String? summary;
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final summary = this.summary;
    final blocked = blockedReason;
    return Semantics(
      container: true,
      label: 'What happens',
      child: Container(
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: SurfaceTones.of(context).raised,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (summary != null)
              Text(summary, style: theme.textTheme.bodySmall),
            if (blocked != null) ...[
              if (summary != null) const SizedBox(height: Insets.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(AppIcons.info, size: Chrome.iconSmall, color: muted),
                  const SizedBox(width: Insets.xs),
                  Expanded(
                    child: Text(
                      blocked,
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The packet exactly as the next agent receives it, read before launching.
class PacketPreview extends StatelessWidget {
  const PacketPreview({required this.packet, required this.stale, super.key});

  final String packet;

  /// Whether the instruction or the open tasks changed after this was built.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          // Not "as its first message": an agent that takes a system-prompt
          // file gets the packet as one.
          'This is exactly what the next agent is told:',
          style: theme.textTheme.labelSmall?.copyWith(color: muted),
        ),
        if (stale) ...[
          const SizedBox(height: Insets.xs),
          Row(
            children: [
              Icon(AppIcons.info, size: Chrome.iconSmall, color: muted),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  'Edited since this preview. Preview again to see the '
                  'change.',
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: Insets.xs),
        Container(
          constraints: const BoxConstraints(
            maxHeight: kExpandedOutputMaxHeight,
          ),
          padding: const EdgeInsets.all(Insets.sm),
          decoration: BoxDecoration(
            color: SurfaceTones.of(context).raised,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: SingleChildScrollView(
            primary: false,
            child: SelectableText(
              packet,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
