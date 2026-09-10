import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_hook_installation_service.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_skill_installation_service.dart';
import '../../browser/application/browser_consent_providers.dart';
import 'package:karmashala_browser/browser.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/file_picking.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/application/environment_health.dart'
    show HealthLevel;
import '../../environments/application/system_health.dart';
import '../../environments/application/system_health_service.dart';
import '../../environments/presentation/environment_health_dialog.dart'
    show healthColor, healthIcon;
import '../../mcp/control_server_status.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import '../../projects/application/projects_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../application/settings_controller.dart';
import 'agent_tools_section.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Tools: the external apps sessions are handed to, and the MCP
/// bridge that lets an agent drive Karmashala back.
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  /// The band headings, in order — named here so a test can hold the page.
  static const List<String> categories = [
    'External apps',
    'Agent access',
    'Agent tools',
    'Consent',
  ];

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToolsCategory(
          title: 'External apps',
          blurb:
              'The programs Karmashala hands a session or a folder to when you '
              'open one outside it.',
          children: [TerminalAppSection(), CodeEditorSection()],
        ),
        ToolsCategory(
          title: 'Agent access',
          blurb:
              'Whether an agent pointed at Karmashala can actually reach it — '
              'measured, not assumed.',
          children: [McpBridgeSection()],
        ),
        ToolsCategory(
          title: 'Agent tools',
          blurb:
              'What it can call once it is in. Static: this is the catalogue '
              'the bridge serves, not a reading.',
          children: [AgentToolsSection(), AgentSkillsSection()],
        ),
        ToolsCategory(
          title: 'Consent',
          blurb:
              'What an agent may do only because somebody handed it over, and '
              'can take back here.',
          children: [BrowserConsentSection()],
        ),
      ],
    );
  }
}

/// One band of the Tools page, headed heavier than [SettingsSection]'s label.
class ToolsCategory extends StatelessWidget {
  const ToolsCategory({
    required this.title,
    required this.blurb,
    required this.children,
    super.key,
  });

  final String title;
  final String blurb;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            blurb,
            style: theme.textTheme.bodySmall?.copyWith(
              color: SemanticColors.of(context).neutral,
            ),
          ),
        ),
        const Divider(height: Insets.lg),
        ...children,
      ],
    );
  }
}

/// The external terminal sessions resume in: a detected one, or a custom path.
class TerminalAppSection extends ConsumerStatefulWidget {
  const TerminalAppSection({super.key});

  @override
  ConsumerState<TerminalAppSection> createState() => _TerminalAppSectionState();
}

class _TerminalAppSectionState extends ConsumerState<TerminalAppSection> {
  final _path = TextEditingController();

  @override
  void initState() {
    super.initState();
    _path.text = ref.read(settingsControllerProvider).customTerminalPath ?? '';
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final file = await pickOneFile(
      what: 'a terminal program',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Executables', extensions: ['exe']),
      ],
    );
    if (file == null) return;
    _path.text = file.path;
    ref
        .read(settingsControllerProvider.notifier)
        .setCustomTerminalPath(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final detected =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    // Clamp to a valid option: the saved terminal can be absent from
    // `detected` while the probe loads, and DropdownButtonFormField throws.
    final validIds = <String>{for (final t in detected) t.id, 'custom'};
    final saved = settings.defaultSystemTerminalId;
    final current = (saved != null && validIds.contains(saved))
        ? saved
        : (detected.isNotEmpty ? detected.first.id : 'custom');
    final isCustom = current == 'custom';

    return SettingsSection(
      title: 'TERMINAL APP (resumes sessions)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Open sessions in',
            control: DropdownButtonFormField<String>(
              initialValue: current,
              isExpanded: true,
              items: [
                for (final t in detected)
                  DropdownMenuItem(value: t.id, child: Text(t.label)),
                const DropdownMenuItem(
                  value: 'custom',
                  child: Text('Custom executable…'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                if (v == 'custom') {
                  controller.setCustomTerminalPath(_path.text.trim());
                } else {
                  controller.setDefaultSystemTerminal(v);
                }
              },
            ),
          ),
          if (isCustom) ...[
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Terminal executable path',
                      hintText: _hostPathHint('terminal'),
                    ),
                    onChanged: (v) =>
                        controller.setCustomTerminalPath(v.trim()),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
                  label: const Text('Browse'),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'The session\'s agent runs in this app (cwd set to the repo); '
              'flags vary by terminal, so it is best-effort.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// The editor "open in editor" uses: a detected one, or a custom path.
class CodeEditorSection extends ConsumerStatefulWidget {
  const CodeEditorSection({super.key});

  @override
  ConsumerState<CodeEditorSection> createState() => _CodeEditorSectionState();
}

class _CodeEditorSectionState extends ConsumerState<CodeEditorSection> {
  final _path = TextEditingController();

  @override
  void initState() {
    super.initState();
    _path.text = ref.read(settingsControllerProvider).customEditorPath ?? '';
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final file = await pickOneFile(
      what: 'an editor program',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Executables', extensions: ['exe']),
      ],
    );
    if (file == null) return;
    _path.text = file.path;
    ref
        .read(settingsControllerProvider.notifier)
        .setCustomEditorPath(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final detected =
        ref.watch(availableCodeEditorsProvider).asData?.value ?? const [];
    final isCustom = settings.defaultCodeEditorId == 'custom';
    final current = settings.defaultCodeEditorId == null && detected.isEmpty
        ? 'custom'
        : (settings.defaultCodeEditorId ??
              (detected.isNotEmpty ? detected.first.id : 'custom'));

    return SettingsSection(
      title: 'CODE EDITOR (open in editor)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Open folders in',
            control: DropdownButtonFormField<String>(
              initialValue: current,
              isExpanded: true,
              items: [
                for (final e in detected)
                  DropdownMenuItem(value: e.id, child: Text(e.label)),
                const DropdownMenuItem(
                  value: 'custom',
                  child: Text('Custom executable…'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                if (v == 'custom') {
                  controller.setCustomEditorPath(_path.text.trim());
                } else {
                  controller.setDefaultCodeEditor(v);
                }
              },
            ),
          ),
          if (isCustom) ...[
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Editor executable path',
                      hintText: _hostPathHint('editor'),
                    ),
                    onChanged: (v) => controller.setCustomEditorPath(v.trim()),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
                  label: const Text('Browse'),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'The editor opens with the folder path as its argument '
              '(e.g. `editor.exe <folder>`).',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

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
      title: 'MCP BRIDGE',
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
            Row(
              children: [
                Icon(
                  AppIcons.warningCircle,
                  size: Chrome.icon,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    control.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
            if (control.failureDetail case final detail?)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs, left: 20),
                child: Text(detail, style: theme.textTheme.bodySmall),
              ),
          ],
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
    final theme = Theme.of(context);
    final color = _unknown
        ? healthColor(context, HealthLevel.unknown)
        : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _unknown ? healthIcon(HealthLevel.unknown) : AppIcons.warningCircle,
            size: Chrome.icon,
            color: color,
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
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
                  ? const SizedBox(
                      width: Chrome.icon,
                      height: Chrome.icon,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
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
                      'Checked ${describeAge(
                        ref.read(clockProvider).nowUtc().difference(checkedAt),
                      )}.',
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

/// An example path in this host's shape — `C:\path\to\...` is wrong on a Mac.
String _hostPathHint(String what) {
  if (Platform.isWindows) return r'C:\path\to\' '$what.exe';
  if (Platform.isMacOS) return '/Applications/My$what.app/Contents/MacOS/$what';
  return '/usr/local/bin/$what';
}

/// Settings → Tools → Browser: a per-project consent switch rather than a
/// prompt on first `browser_evaluate` — the agent may run with nobody there.
class BrowserConsentSection extends ConsumerWidget {
  const BrowserConsentSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projects = ref.watch(projectsControllerProvider);
    final store = ref.watch(browserConsentStoreProvider);
    // The store reads storage per call, so there is nothing to watch.
    ref.watch(browserConsentRevisionProvider);

    return SettingsSection(
      title: 'BROWSER',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              'browser_evaluate runs whatever JavaScript an agent composes '
              'inside a page you are already logged in to, so it can read '
              'cookies and stored tokens as easily as it reads the DOM — and '
              'nothing about it shows in the browser pane. It is refused until '
              'you allow it, per project. Finding, capturing and screenshotting '
              'a page never need this.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (projects.isEmpty)
            Text(
              'No projects yet. Add one and it will be listed here.',
              style: theme.textTheme.bodySmall,
            )
          else
            for (final project in projects)
              Builder(
                builder: (context) {
                  final grant = store.grantFor(
                    project.id,
                    BrowserCapability.evaluate,
                  );
                  return SettingsSwitchRow(
                    label: 'Run JavaScript in the page — ${project.name}',
                    // The date is why a grant is a record, not a boolean.
                    help: grant == null
                        ? 'Not allowed. Agents working in this project cannot '
                              'call browser_evaluate.'
                        : 'Allowed since '
                              '${grant.grantedAt.toLocal()} '
                              '(${grant.grantedBy}).',
                    value: grant != null,
                    onChanged: (allow) {
                      if (allow) {
                        store.grant(
                          project.id,
                          BrowserCapability.evaluate,
                          grantedBy: 'Settings → Tools → Browser',
                        );
                      } else {
                        store.revoke(project.id, BrowserCapability.evaluate);
                      }
                      ref
                          .read(browserConsentRevisionProvider.notifier)
                          .bump();
                    },
                  );
                },
              ),
        ],
      ),
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
      title: 'SKILLS',
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
