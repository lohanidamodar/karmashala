import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:file_selector/file_selector.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../mcp/control_server_status.dart';
import '../../mcp/launcher_control_server.dart';
import '../../mcp/launcher_mcp.dart';
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
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Terminal executable path',
                      hintText: r'C:\path\to\terminal.exe',
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
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Editor executable path',
                      hintText: r'C:\path\to\editor.exe',
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
    final bridge = const LauncherMcp().bridgeExecutable();
    final available = bridge != null;
    final control = ref.watch(controlServerStatusProvider);
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
          Row(
            children: [
              Icon(
                available ? AppIcons.checkCircle : AppIcons.warningCircle,
                size: Chrome.icon,
                color: available
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  available
                      ? 'Tools available — the MCP bridge is installed.'
                      : 'Tools unavailable — the MCP bridge (karmashala_mcp) '
                            'was not found next to the app.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
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
        ],
      ),
    );
  }
}
