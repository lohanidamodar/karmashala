import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/application/agent_hook_installation_service.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_skill_installation_service.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/application/environment_health.dart'
    show HealthLevel;
import '../../environments/application/system_health.dart';
import '../../environments/application/system_health_service.dart';
import '../../environments/presentation/environment_health_dialog.dart'
    show healthColor, healthIcon;
import '../../mcp/control_server_restart.dart';
import '../../mcp/control_server_status.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'settings_catalog.dart';
import 'settings_section.dart';
import 'settings_notice.dart';

/// The MCP bridge status: can an agent drive Karmashala, and with what.
class McpBridgeSection extends ConsumerWidget {
  const McpBridgeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final report = ref.watch(systemHealthProvider);
    final bridge = report.checkFor(SystemCheckId.mcpBridge);
    final control = ref.watch(controlServerStatusProvider);
    final hooks = ref.watch(agentHookInstallationReportProvider);
    return SettingsSection(
      title: SettingsAnchor.mcpBridge.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'An agent pointed at Karmashala\'s MCP bridge can query and act '
            'on your projects and sessions through the tools listed below.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          // A completed handshake, not the file's existence: on 2026-09-03
          // WSL's interop handler went and a good file would not spawn.
          _BridgeVerdict(check: bridge, report: report),
          // An installed bridge says nothing about the app answering it: a
          // hardening failure withholds privileged RPC, silently.
          if (control.failedClosed) ...[
            const SizedBox(height: Insets.xs),
            SettingsNotice(
              tone: SettingsNoticeTone.danger,
              message: control.message,
            ),
            if (control.failureDetail case final detail?)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs, left: 20),
                child: Text(detail, style: theme.textTheme.bodySmall),
              ),
          ],
          const SizedBox(height: Insets.xs),
          const _ControlServerRestartRow(),
          // A skipped environment loses the two states only a hook reports,
          // and a sweep that has not run yet is `unknown`, not clean (§19).
          if (!hooks.swept) ...[
            const SizedBox(height: Insets.sm),
            const _HookNote.unknown(
              'Status callbacks are not in place yet — that sweep runs just '
              'after the window opens. A session started before it lands '
              'reads the CLI\'s own files until it does, and starts reporting '
              'as soon as it has.',
            ),
          ],
          // Never observed, so it says so rather than guessing either way.
          for (final entry in hooks.unknownByEnvironment.entries)
            _HookNote.unknown(
              'Status callbacks for '
              '${ref.watch(environmentLabelForIdProvider(entry.key))} could '
              'not be confirmed — ${entry.value}. Sessions there may or may '
              'not report; the next launch checks again.',
            ),
          if (hooks.anySkipped) ...[
            const SizedBox(height: Insets.sm),
            for (final entry in hooks.skippedByEnvironment.entries)
              _HookNote.skipped(
                'No status callbacks from '
                '${ref.watch(environmentLabelForIdProvider(entry.key))}'
                ' — '
                '${entry.value}. Sessions there fall back to reading '
                'the CLI\'s files, which cannot tell you when an agent '
                'is waiting for approval or has failed.',
              ),
          ],
        ],
      ),
    );
  }
}

/// One line about the hook sweep. A constructor per claim, not a colour (§19).
class _HookNote extends StatelessWidget {
  /// An observed failure of the callback path.
  const _HookNote.skipped(this.text) : _unknown = false;

  /// A reading nobody took.
  const _HookNote.unknown(this.text) : _unknown = true;

  final String text;
  final bool _unknown;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: SettingsNotice(
        tone: _unknown ? SettingsNoticeTone.neutral : SettingsNoticeTone.danger,
        icon: _unknown ? healthIcon(HealthLevel.unknown) : null,
        message: text,
      ),
    );
  }
}

/// The MCP bridge's verdict, from the same reading the System health panel
/// shows — one probe, so two surfaces cannot disagree about one file.
class _BridgeVerdict extends ConsumerWidget {
  const _BridgeVerdict({required this.check, required this.report});

  final SystemCheck? check;
  final SystemHealthReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final current = check;
    final checkedAt = report.checkedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: report.running
                  ? const InlineSpinner(size: InlineSpinnerSize.medium)
                  : Icon(
                      current == null
                          ? AppIcons.question
                          : healthIcon(current.level),
                      size: Chrome.icon,
                      color: current == null
                          ? semantic.neutral
                          : healthColor(context, current.level),
                    ),
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    current?.summary ??
                        'Not checked. Whether the bridge works is a question '
                            'about a process, not a file, so answering it '
                            'means starting one — which happens when you '
                            'ask.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (current != null && checkedAt != null)
                    Text(
                      'Checked ${describeAge(ref.read(clockProvider).nowUtc().difference(checkedAt))}.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: semantic.neutral,
                      ),
                    ),
                  if (current?.detail case final detail?
                      when detail.trim().isNotEmpty)
                    Text(detail, style: MonoStyles.small),
                  if (current?.remedy case final remedy?)
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.xs),
                      child: Text(
                        remedy,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: report.running
                ? null
                : () => ref.read(systemHealthProvider.notifier).refresh(),
            icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
            label: Text(current == null ? 'Check the bridge' : 'Check again'),
          ),
        ),
      ],
    );
  }
}

/// The skills written into the agent CLIs here, read off disk by the
/// once-a-launch sweep and shown with the age of that reading (§19).
class AgentSkillsSection extends ConsumerWidget {
  const AgentSkillsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final report = ref.watch(agentSkillInstallationReportProvider);
    final registry = ref.watch(agentRegistryProvider);
    return SettingsSection(
      title: SettingsAnchor.skills.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The tools above have to be called by an agent that already '
            'suspects they exist. A skill is found by the CLI without being '
            'asked for, so Karmashala writes three into each agent it finds: '
            'one that points at instructions(), and two for asking another '
            'agent family for a second opinion.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          if (!report.swept)
            const _HookNote.unknown(
              'Not written yet — that sweep runs just after the window opens.',
            )
          else ...[
            for (final row in report.complete)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      AppIcons.checkCircle,
                      size: Chrome.icon,
                      color: healthColor(context, HealthLevel.healthy),
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        '${row.installed} skills for '
                        '${registry.displayNameFor(row.agentId)} in '
                        '${ref.watch(environmentLabelForIdProvider(row.environmentId))}'
                        '${row.root == null ? '' : ' — ${row.root}'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            for (final entry in report.unknownByAgent.entries)
              _HookNote.unknown(
                'Whether ${registry.displayNameFor(entry.key)} has them could '
                'not be confirmed — ${entry.value}.',
              ),
            for (final entry in report.incompleteByAgent.entries)
              _HookNote.skipped(
                'No skills for ${registry.displayNameFor(entry.key)} — '
                '${entry.value}.',
              ),
            if (report.complete.isEmpty &&
                report.unknownByAgent.isEmpty &&
                report.incompleteByAgent.isEmpty)
              Text(
                'Nothing is installed. No agent on this machine declares a '
                'place to put one.',
                style: theme.textTheme.bodySmall,
              ),
            if (report.checkedAt case final at?)
              Text(
                'Read ${describeAge(ref.read(clockProvider).nowUtc().difference(at))}.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
          const SizedBox(height: Insets.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref
                  .read(agentSkillInstallationServiceProvider)
                  .sweepRemoval(),
              icon: const Icon(AppIcons.trash, size: Chrome.icon),
              label: const Text('Remove them'),
            ),
          ),
        ],
      ),
    );
  }
}

/// **Rebinds this app's own control server**, and says what that did.
///
/// Only this app's endpoint: the bridge an agent session spawns is the CLI's
/// own child, bound when that session started, and nothing here can restart it
/// (§19 — this app speaks for its own bridge and its own endpoint).
class _ControlServerRestartRow extends ConsumerStatefulWidget {
  const _ControlServerRestartRow();

  @override
  ConsumerState<_ControlServerRestartRow> createState() =>
      _ControlServerRestartRowState();
}

class _ControlServerRestartRowState
    extends ConsumerState<_ControlServerRestartRow> {
  ControlServerRestart? _last;

  Future<void> _restart() async {
    final result = await restartControlServer(ref.container);
    if (!mounted) return;
    setState(() => _last = result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = ref.watch(controlServerRestartingProvider);
    final status = ref.watch(controlServerStatusProvider);
    final started = ref.watch(controlServerHandleProvider) != null;
    final up = status.transport != PrivilegedRpcTransport.notStarted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: running || !started ? null : _restart,
            icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
            label: Text(
              running
                  ? 'Restarting\u2026'
                  : up
                  ? 'Restart the control server'
                  : 'Start the control server',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: Insets.sm),
          child: Text(
            // Said before it is pressed, because it is the consequence a user
            // cannot see: the token lives in every agent's own config file.
            'Rebinds the port and the owner-only socket, then rewrites every '
            "agent's hook token \u2014 a restart mints a new one.",
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (_last case final ControlServerRestart result) ...[
          const SizedBox(height: Insets.xs),
          Padding(
            padding: const EdgeInsets.only(left: Insets.sm),
            child: Text(
              result.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: result.ok ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
