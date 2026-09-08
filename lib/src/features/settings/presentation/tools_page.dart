import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_hook_installation_service.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_skill_installation_service.dart';
import '../../browser/application/browser_consent_providers.dart';
import '../../browser/domain/browser_consent.dart';
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
import '../../sessions/domain/session_resume.dart' show describeAge;
import '../../projects/application/projects_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../application/settings_controller.dart';
import 'agent_tools_section.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Tools: the external apps sessions are handed to, and the MCP
/// bridge that lets an agent drive Karmashala back.
///
/// ## Why the page is banded
///
/// Four blocks in a column all looked like one list of unrelated settings, and
/// the two questions they actually answer are different in kind. "Which
/// program opens this" is a preference. "Can an agent reach Karmashala at all"
/// is a measurement (§19), and "may it run JavaScript in my logged-in browser"
/// is a decision only a person can make. Bands say which is which before the
/// reader has to work it out from the controls.
///
/// The order is a progression: what we hand work to, whether an agent can get
/// in, what it can call once it is in, and the one thing it cannot do until
/// you say so.
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  /// The band headings, in order — named here so a test can hold the page to
  /// them without restating the strings and drifting from the page.
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

/// One band of the Tools page: a heading, a line saying what the band is
/// about, and the sections under it.
///
/// A heavier heading than [SettingsSection]'s label deliberately — the two are
/// nested, and a band whose title looked like a section title would read as a
/// fifth section rather than as the thing three of them sit inside.
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
            'on your projects and sessions through the tools listed below.',
            style: theme.textTheme.bodySmall,
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
          //
          // **Three states, not two, and the first one is new.** The sweep runs
          // after the first frame now rather than before the window
          // (`AppLifecycle.installAgentHooks`), so there is a real moment early
          // in a launch when the answer is *not yet*. An empty report used to
          // be indistinguishable from a clean one, which would have put this
          // panel's silence — read as "the hooks are fine" — on screen during
          // exactly the window in which they are not. §19's rule is that an
          // unobserved state gets `unknown`'s icon and the neutral colour, so
          // it does.
          if (!hooks.swept) ...[
            const SizedBox(height: Insets.sm),
            const _HookNote.unknown(
              'Status callbacks are not in place yet — that sweep runs just '
              'after the window opens. A session started before it lands '
              'reads the CLI\'s own files until it does, and starts reporting '
              'as soon as it has.',
            ),
          ],
          // A store home that never answered. Not the same claim as a skip and
          // deliberately not dressed as one: what is on disk there was never
          // observed, so this says so rather than guessing either way.
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


/// One line about the hook sweep.
///
/// Two constructors rather than a colour argument, because which one a row gets
/// is the claim it is making and not a styling choice. [_HookNote.skipped] says
/// *we know these callbacks are not there*; [_HookNote.unknown] says *we do not
/// know*, in `HealthLevel.unknown`'s own icon and the neutral colour — the same
/// vocabulary the system-health panel uses, so an admission of ignorance is not
/// read as a quieter failure. §19 of `CLAUDE.md` is the rule.
class _HookNote extends StatelessWidget {
  /// An observed failure of the callback path, worded and coloured exactly as
  /// it was before the unknown case existed.
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


/// Settings → Tools → Agent tools: the skills this app has written into the
/// agent CLIs on this machine.
///
/// **Three claims, and each is a different kind of statement.** What is
/// installed is read off disk by the sweep, not assumed from having written
/// it. For which agent, because a skill goes into one CLI's own skills root
/// and a machine has more than one. And the age of the reading, because §19's
/// rule is that a measurement without its age is a claim — the sweep runs once
/// a launch and nothing polls, so what is on screen can be hours old and must
/// say so.
///
/// The button is the other half of writing into somebody's home: the code that
/// wrote the directories is the code that removes them, and it is reachable
/// from the same place that says they are there.
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
