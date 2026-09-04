import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:file_selector/file_selector.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_hook_installation_service.dart';
import '../../browser/application/browser_consent_providers.dart';
import '../../browser/domain/browser_consent.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/application/system_health.dart';
import '../../environments/application/system_health_service.dart';
import '../../environments/presentation/environment_health_dialog.dart'
    show healthColor, healthIcon;
import '../../mcp/control_server_status.dart';
import '../../mcp/launcher_control_server.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
import '../../projects/application/projects_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../application/settings_controller.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Tools: the external apps sessions are handed to, and the MCP
/// bridge that lets an agent drive Karmashala back.
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TerminalAppSection(),
        CodeEditorSection(),
        McpBridgeSection(),
        BrowserConsentSection(),
      ],
    );
  }
}

/// The external terminal app used to resume sessions: a detected terminal or
/// a custom executable (browse or paste path).
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
    final file = await openFile(
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
    // The dropdown value must match exactly one item, so clamp the saved
    // selection to a currently-valid option. The saved terminal can be missing
    // from `detected` while the async probe is still loading (or if it was
    // uninstalled); without this clamp DropdownButtonFormField throws and the
    // settings screen flashes a red error until the probe resolves.
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

/// The code editor used by "open in editor" on projects: a detected editor
/// (VS Code, Zed) or a custom executable (browse or paste path).
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
    final file = await openFile(
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

/// The MCP bridge status: whether an agent can drive Karmashala through its
/// own tools, and which tools are exposed.
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
            'on your projects and sessions through these built-in tools:',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              for (final tool in LauncherControlServer.toolSchemas)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(tool['name'] as String, style: MonoStyles.small),
                ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          // **This used to read "Tools available — the MCP bridge is
          // installed" whenever the file existed.** On 2026-09-03 it said so
          // for over an hour while every agent session on this machine had no
          // Karmashala tools at all: WSL's interop handler had gone, and the
          // perfectly good file could not be spawned by the process that
          // needed it. So the claim is now a measurement or it is nothing —
          // the bridge is started and made to complete an MCP handshake, and
          // until that has happened this says it has not.
          _BridgeVerdict(check: bridge, report: report),
          // The other half of "can an agent drive this app": the bridge being
          // installed says nothing about whether the app is willing to answer
          // it. When hardening fails the server withholds privileged RPC
          // deliberately, and the tools above simply stop working — silently,
          // unless this says so.
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
          // And the third half of it: hooks. A skipped environment costs every
          // session in it the two states only a hook can report — awaiting
          // approval, and failed — for the whole run. That used to be one line
          // in a log file, so nine sessions ran on disk probes all day with
          // nothing on screen saying the app had quietly stopped being able to
          // tell you your agent was blocked.
          if (hooks.anySkipped) ...[
            const SizedBox(height: Insets.sm),
            for (final entry in hooks.skippedByEnvironment.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      AppIcons.warningCircle,
                      size: Chrome.icon,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        'No status callbacks from '
                        '${ref.watch(environmentLabelForIdProvider(entry.key))}'
                        ' — '
                        '${entry.value}. Sessions there fall back to reading '
                        'the CLI\'s files, which cannot tell you when an agent '
                        'is waiting for approval or has failed.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}


/// The MCP bridge's verdict on the settings page, from the same reading the
/// System health panel shows.
///
/// One source deliberately: two surfaces each running their own probe could
/// report different things about one file, which is a smaller copy of the bug
/// that made this feature necessary.
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

/// An example path in the shape this host actually uses.
///
/// The hint read `C:\path\to\editor.exe` everywhere, which on a Mac is an
/// example of something the field will not accept.
String _hostPathHint(String what) {
  if (Platform.isWindows) return r'C:\path\to\' '$what.exe';
  if (Platform.isMacOS) return '/Applications/My$what.app/Contents/MacOS/$what';
  return '/usr/local/bin/$what';
}

/// Settings → Tools → Browser: the one browser capability an agent cannot have
/// until a person hands it over.
///
/// ## Why the grant lives here and not in a prompt
///
/// The obvious design is a dialog on the first `browser_evaluate`. It is worse
/// than it looks. The agent may be working while nobody is at the machine, so
/// the dialog blocks a turn on a person who is not there; and a prompt that
/// appears mid-flow is a prompt that gets approved without being read, which is
/// how consent becomes a formality. A switch on a settings page is a decision
/// someone makes deliberately, in a place they can come back to — which is the
/// same place they will look when they want it back.
///
/// It is per project, and the switch names the project, because that is the
/// unit the developer thinks in. The gate resolves a call's project from the
/// calling session's checkout, falling back to the checkout the Explorer is
/// pointed at — see `browser_consent_providers.dart`.
class BrowserConsentSection extends ConsumerWidget {
  const BrowserConsentSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projects = ref.watch(projectsControllerProvider);
    final store = ref.watch(browserConsentStoreProvider);
    // The store reads storage on every call rather than holding state, so that
    // a grant taken back here is in force on the very next tool call. The cost
    // is that there is nothing for the UI to watch — hence the revision.
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
                    // The date is the whole reason a grant is a record rather
                    // than a boolean: "I allowed this at some point" and "I
                    // allowed this on the 3rd" are different things to a person
                    // deciding whether to take it back.
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
