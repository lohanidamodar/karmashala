import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_providers.dart';
import '../application/automation_providers.dart';
import '../application/unattended_preflight.dart';
import 'automation_dialog.dart';
import 'webhook_panel.dart';

/// Arming or editing a webhook: an automation that starts a new session when
/// its URL is called. The server chooses its hook id and makes its secret,
/// which is shown once, after the save.
class WebhookDialog extends ConsumerStatefulWidget {
  const WebhookDialog({required this.repository, this.existing, super.key});

  final Repository repository;
  final Automation? existing;

  static Future<void> show(
    BuildContext context, {
    required Repository? repository,
    Automation? existing,
  }) {
    if (repository == null) return Future<void>.value();
    return showDialog<void>(
      context: context,
      builder: (_) => WebhookDialog(repository: repository, existing: existing),
    );
  }

  @override
  ConsumerState<WebhookDialog> createState() => _WebhookDialogState();
}

class _WebhookDialogState extends ConsumerState<WebhookDialog> {
  late final TextEditingController _name;
  late final TextEditingController _template;
  late final TextEditingController _model;
  late final TextEditingController _perHour;
  late final String _id;
  String? _installationId;
  PermissionSelection? _mode;
  late bool _signed;
  late bool _worktree;
  String? _failure;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final webhook = existing?.webhook;
    _id = existing?.id ?? ref.read(automationControllerProvider).newId();
    _name = TextEditingController(text: existing?.name ?? '');
    _template = TextEditingController(text: existing?.prompt ?? '');
    _model = TextEditingController(text: existing?.modelId ?? '');
    _perHour = TextEditingController(
      text: '${webhook?.callsPerHour ?? kDefaultWebhookCallsPerHour}',
    );
    _installationId = existing?.agentInstallationId;
    _mode = existing?.permissionMode;
    _signed = webhook?.requireSignature ?? true;
    _worktree = existing?.worktree ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _template.dispose();
    _model.dispose();
    _perHour.dispose();
    super.dispose();
  }

  List<AgentInstallation> get _installations => ref
      .read(agentInstallationsDataProvider)
      .getByEnvironment(widget.repository.path.environmentId);

  /// The agent's least permissive mode that reads and changes nothing — the
  /// default a webhook starts under until its owner chooses otherwise.
  static PermissionSelection? _readOnlyOf(AgentPermissionSupport? support) {
    if (support == null || !support.isKnown) return null;
    for (final selection in support.selections()) {
      if (support.riskOf(selection) == PermissionRisk.readOnly) {
        return selection;
      }
    }
    return null;
  }

  int? get _callsPerHour {
    final value = int.tryParse(_perHour.text.trim());
    return value == null || value < 1 || value > kMaxWebhookCallsPerHour
        ? null
        : value;
  }

  Automation? get _candidate {
    final installationId = _installationId;
    final perHour = _callsPerHour;
    if (installationId == null || perHour == null) return null;
    if (_name.text.trim().isEmpty) return null;
    if (webhookTemplateRefusal(_template.text) != null) return null;
    final existing = widget.existing;
    final model = _model.text.trim();
    final now = ref.read(automationControllerProvider).now();
    return Automation(
      id: _id,
      repositoryId: widget.repository.id,
      name: _name.text.trim(),
      schedule: existing?.schedule ?? AutomationSchedule.once(now),
      agentInstallationId: installationId,
      prompt: _template.text.trim(),
      permissionMode: _mode,
      enabled: existing?.enabled ?? true,
      armedAt: existing?.armedAt ?? now,
      stopAfterFailures:
          existing?.stopAfterFailures ?? kDefaultStopAfterFailures,
      consecutiveFailures: existing?.consecutiveFailures ?? 0,
      maxRuntime: existing?.maxRuntime,
      modelId: model.isEmpty ? null : model,
      worktree: _worktree,
      steps: existing?.steps ?? AutomationSteps.standard,
      webhook: AutomationWebhook(
        hookId: existing?.webhook?.hookId ?? '',
        requireSignature: _signed,
        callsPerHour: perHour,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final registry = ref.watch(agentRegistryProvider);
    final preflight = ref.watch(unattendedPreflightProvider);
    final installations = _installations;
    final selected = installations
        .where((i) => i.id == _installationId)
        .firstOrNull;
    final descriptor = selected == null
        ? null
        : registry.byId(selected.agentId);
    final candidate = _candidate;
    final refusal = candidate == null ? null : preflight.refusalFor(candidate);
    final templateRefusal = _template.text.trim().isEmpty
        ? null
        : webhookTemplateRefusal(_template.text);
    final fields = templateRefusal == null
        ? webhookTemplateFields(_template.text)
        : const <String>[];
    final error = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      scrollable: true,
      title: DesktopDialogTitle(
        icon: AppIcons.globe,
        title: widget.existing == null
            ? 'New webhook in ${widget.repository.name}'
            : 'Edit "${widget.existing!.name}"',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_failure case final failure?) ...[
              DesktopErrorBanner(failure),
              const SizedBox(height: Insets.sm),
            ],
            Text(
              'A call to its URL, from anywhere, starts one new session here '
              'with the prompt below, filled from the call\'s JSON body.',
              style: quiet,
            ),
            const SizedBox(height: Insets.sm),
            TextField(
              key: const ValueKey('webhook-name'),
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'triage-issue',
              ),
            ),
            const SizedBox(height: Insets.sm),
            KeyedSubtree(
              key: const ValueKey('webhook-agent'),
              child: AutomationAgentField(
                installations: installations,
                selectedId: _installationId,
                displayNameFor: registry.displayNameFor,
                onChanged: (value) => setState(() {
                  _installationId = value;
                  final installation = installations
                      .where((i) => i.id == value)
                      .firstOrNull;
                  _mode = installation == null
                      ? null
                      : _readOnlyOf(
                          registry
                              .byId(installation.agentId)
                              ?.launch
                              .permission,
                        );
                }),
              ),
            ),
            const SizedBox(height: Insets.sm),
            if (selected != null) ...[
              AutomationPermissionModeField(
                agentName: descriptor?.displayName ?? selected.agentId,
                support: descriptor?.launch.permission,
                value: _mode,
                onChanged: (value) => setState(() => _mode = value),
              ),
              const SizedBox(height: Insets.sm),
            ],
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Model (optional)',
                hintText: "The agent's default",
              ),
            ),
            const SizedBox(height: Insets.sm),
            TextField(
              key: const ValueKey('webhook-template'),
              controller: _template,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Prompt template',
                hintText: 'Triage issue {{issue.title}} from {{sender.login}}',
              ),
            ),
            const SizedBox(height: Insets.xs),
            if (templateRefusal != null)
              Text(templateRefusal, style: error)
            else
              Text(
                fields.isEmpty
                    ? 'Reads no fields: every call sends this text as written.'
                    : 'Reads ${fields.join(', ')}',
                style: quiet,
              ),
            Text(
              'Each value is quoted as data inside a fence, never as an '
              'instruction, and cut at $kWebhookValueCap characters.',
              style: quiet,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _signed,
              onChanged: (value) => setState(() => _signed = value),
              title: const Text('Require a signature'),
              subtitle: Text(
                _signed
                    ? 'Calls must carry an HMAC-SHA256 of the body with its '
                          'secret (GitHub\'s X-Hub-Signature-256 works).'
                    : 'Anyone who has the URL can start a session.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _worktree,
              onChanged: (value) => setState(() => _worktree = value),
              title: const Text('Start each call in a worktree of its own'),
            ),
            TextField(
              controller: _perHour,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Calls accepted an hour',
                errorText: _callsPerHour == null
                    ? 'A whole number from 1 to $kMaxWebhookCallsPerHour.'
                    : null,
              ),
            ),
            if (refusal != null) ...[
              const SizedBox(height: Insets.sm),
              Text(refusal.reason, style: error),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: candidate == null || refusal != null || _saving
              ? null
              : _save,
          child: Text(widget.existing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final controller = ref.read(automationControllerProvider);
    final data = ref.read(automationsDataProvider);
    final candidate = _candidate!;
    final existing = widget.existing;
    setState(() => _saving = true);
    try {
      // Arming dates the authorisation; an edit re-dates it.
      final stored = await data.saveAndWait(
        candidate.copyWith(armedAt: controller.now()),
      );
      if (existing != null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final issued = await data.rotateWebhook(stored.id);
      if (!mounted) return;
      final navigator = Navigator.of(context);
      navigator.pop();
      await WebhookSecretDialog.show(navigator.context, issued);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failure = '$error';
        });
      }
    }
  }
}
