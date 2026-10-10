import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/pipelines.dart' show kPipelineTemplates;
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/unattended.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_model_catalog_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/model_picker.dart';
import '../../pipelines/application/pipelines_controller.dart'
    show pipelinesProvider;
import '../../settings/presentation/settings_row.dart';

import '../application/automation_draft.dart';
import '../application/automation_editor_state.dart';
import '../application/automation_providers.dart';
import '../application/unattended_preflight.dart';
import '../application/automation_dry_run.dart';
import 'automation_agent_fields.dart';
import 'automation_dry_run_dialog.dart';
import 'automation_run_actions.dart';
import 'automation_run_status.dart';
import 'automation_editor_parts.dart';

import 'turn_on_confirm_dialog.dart' show confirmTurnOn;
import 'webhook_parts.dart';

part 'automation_editor/readiness.dart';
part 'automation_editor/step_fields.dart';
part 'automation_editor/trigger_fields.dart';

/// **The one editor** for every kind of automation: its name, what starts it,
/// the agent and the steps after it, whether it is ready to run with nobody
/// watching, and its limits. Saving is the authorisation; nothing else arms.
class AutomationEditor extends ConsumerStatefulWidget {
  const AutomationEditor({required this.initial, super.key});

  final AutomationDraft initial;

  @override
  ConsumerState<AutomationEditor> createState() => _AutomationEditorState();
}

class _AutomationEditorState extends ConsumerState<AutomationEditor> {
  late AutomationDraft _draft = widget.initial;
  late final _name = TextEditingController(text: _draft.name);
  late final _prompt = TextEditingController(text: _draft.prompt);
  late final _cron = TextEditingController(text: _draft.cron);
  late final _every = TextEditingController(text: '${_draft.everyMinutes}');
  late final _tell = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.tell)?.text ?? kDefaultTellText,
  );
  late final _notify = TextEditingController(
    text:
        _draft.steps.of(AutomationStepKind.notify)?.text ?? kDefaultNotifyText,
  );
  late final _command = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.command)?.text ?? '',
  );
  late final _checkCommand = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.check)?.text ?? '',
  );
  late final _checkName = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.check)?.name ?? '',
  );
  late final _hookUrl = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.webhook)?.url ?? '',
  );
  late final _pipelineInput = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.pipeline)?.text ?? '',
  );
  late final _hookBody = TextEditingController(
    text:
        _draft.steps.of(AutomationStepKind.webhook)?.text ??
        kDefaultWebhookBody,
  );
  late final _ghRepo = TextEditingController(text: _draft.github.repository);
  late final _perHour = TextEditingController(text: '$_perHourValue');
  late final _queueLimit = TextEditingController(text: '${_draft.queueLimit}');

  /// A webhook's limit is its calls an hour; every other kind's, its runs.
  int get _perHourValue => _draft.trigger == DraftTrigger.webhook
      ? _draft.callsPerHour
      : _draft.runsPerHour;
  late final _stopAfter = TextEditingController(
    text: '${_draft.stopAfterFailures}',
  );
  late final _longest = TextEditingController(
    text: _draft.maxRuntimeMinutes?.toString() ?? '',
  );
  var _saving = false;
  String? _failure;

  /// Changes not saved yet: Run now runs what is saved, so it waits.
  var _dirty = false;

  /// The last dry run, by card, while nothing changed since.
  Map<String, DryRunStep>? _dry;

  /// The run Run now started, followed here as it goes.
  String? _runId;

  @override
  void dispose() {
    for (final c in [
      _name,
      _prompt,
      _cron,
      _every,
      _tell,
      _notify,
      _command,
      _checkCommand,
      _checkName,
      _hookUrl,
      _hookBody,
      _pipelineInput,
      _ghRepo,
      _perHour,
      _queueLimit,
      _stopAfter,
      _longest,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _update(AutomationDraft draft) => setState(() {
    _draft = draft;
    _dirty = true;
    _dry = null;
  });

  void _putStep(
    AutomationStepKind kind, {
    AutomationStepWhen? when,
    bool? allowPrivate,
    int? timeoutSeconds,
    String? pipelineId,
    String? pipelineCheckout,
    bool ownCheckout = false,
  }) {
    final existing = _draft.steps.of(kind);
    final text = switch (kind) {
      AutomationStepKind.tell => _tell.text,
      AutomationStepKind.notify => _notify.text,
      AutomationStepKind.command => _command.text,
      AutomationStepKind.webhook => _hookBody.text,
      AutomationStepKind.pipeline => _pipelineInput.text,
      AutomationStepKind.check => _checkCommand.text,
    };
    _update(
      _draft.copyWith(
        steps: _draft.steps.put(
          AutomationStep(
            kind: kind,
            when: when ?? existing?.when ?? _defaultWhen(kind),
            text: text,
            name: kind == AutomationStepKind.check
                ? _checkName.text.trim()
                : '',
            url: kind == AutomationStepKind.webhook ? _hookUrl.text.trim() : '',
            allowPrivate: allowPrivate ?? existing?.allowPrivate ?? false,
            timeoutSeconds: timeoutSeconds ?? existing?.timeoutSeconds,
            pipelineId:
                pipelineId ??
                existing?.pipelineId ??
                (kind == AutomationStepKind.pipeline
                    ? kPipelineTemplates.first.id
                    : ''),
            repositoryId: ownCheckout
                ? null
                : pipelineCheckout ?? existing?.repositoryId,
          ),
        ),
      ),
    );
  }

  static AutomationStepWhen _defaultWhen(AutomationStepKind kind) =>
      switch (kind) {
        AutomationStepKind.tell => AutomationStepWhen.failure,
        AutomationStepKind.notify ||
        AutomationStepKind.webhook => AutomationStepWhen.always,
        AutomationStepKind.check ||
        AutomationStepKind.command ||
        AutomationStepKind.pipeline => AutomationStepWhen.success,
      };

  Repository? _repository(List<Repository> all) =>
      all.where((r) => r.id == _draft.repositoryId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final repositories = ref.watch(automationCheckoutsProvider);
    final repository = _repository(repositories);
    final registry = ref.watch(agentRegistryProvider);
    final installations = repository == null
        ? const <AgentInstallation>[]
        : ref
              .watch(agentInstallationsDataProvider)
              .getByEnvironment(repository.path.environmentId);
    final installation = installations
        .where((i) => i.id == _draft.installationId)
        .firstOrNull;
    final descriptor = installation == null
        ? null
        : registry.byId(installation.agentId);
    final now = ref.watch(clockProvider).nowUtc();
    ref.watch(automationsRevisionProvider);
    final probe = _draft.probe(now: now);
    final refusal = probe == null || !probe.startsAgent
        ? null
        : ref.watch(unattendedPreflightProvider).refusalFor(probe);
    final readiness = _readiness(
      installation: installation,
      descriptor: descriptor,
      refusal: refusal,
    );
    final ready = readiness.every((row) => row.ok);
    final missing = _draft.missing;
    final agentName = installation == null
        ? 'the agent'
        : registry.displayNameFor(installation.agentId);
    final summary = probe == null
        ? null
        : automationWords(
            probe,
            checkout: repository?.name ?? 'its checkout',
            agent: agentName,
            now: now,
          );

    return SingleChildScrollView(
      key: const ValueKey('automation-editor'),
      padding: const EdgeInsets.all(Insets.lg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(
                context,
                missing: missing,
                ready: ready,
                probe: probe,
                checkout: repository?.name ?? 'its checkout',
                agent: agentName,
              ),
              if (_banner(context) case final banner?) ...[
                const SizedBox(height: Insets.sm),
                banner,
              ],
              if (_failure case final failure?) ...[
                const SizedBox(height: Insets.sm),
                DesktopErrorBanner(
                  failure,
                  onDismiss: () => setState(() => _failure = null),
                ),
              ],
              const SizedBox(height: Insets.md),
              _Summary(text: summary),
              const SizedBox(height: Insets.md),
              _starts(context, repositories, repository, now),
              const StepLink(),
              _agentStep(context, installations, descriptor, repository),
              ..._afterSteps(context),
              const StepLink(),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _addStepButton(),
              ),
              const SizedBox(height: Insets.lg),
              _ReadyCard(rows: readiness),
              const SizedBox(height: Insets.md),
              _limits(context),
              if (!_draft.isNew) ...[
                const SizedBox(height: Insets.lg),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('automation-delete'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(AppIcons.trash),
                    label: const Text('Delete automation…'),
                    onPressed: () =>
                        confirmDeleteAutomation(context, ref, _draft.original!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context, {
    required String? missing,
    required bool ready,
    required Automation? probe,
    required String checkout,
    required String agent,
  }) {
    final theme = Theme.of(context);
    final blocked = missing ?? (ready ? null : kNotReadyTooltip);
    final original = _draft.original;
    final offered = ref.watch(runNowOfferedProvider);
    final cannotRun = !offered
        ? 'This server cannot run an automation on request.'
        : original == null
        ? 'Create it first.'
        : _dirty
        ? 'Save first: Run now runs what is saved.'
        : blocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('automation-editor-back'),
                  icon: const Icon(AppIcons.arrowLeft),
                  label: const Text(
                    'Automations',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () =>
                      ref.read(automationEditorProvider.notifier).close(),
                ),
              ),
            ),
            Text(
              _draft.enabled ? 'On' : 'Off',
              style: theme.textTheme.bodySmall,
            ),
            Switch(
              key: const ValueKey('automation-enabled'),
              value: _draft.enabled,
              onChanged: (on) => _update(_draft.copyWith(enabled: on)),
            ),
          ],
        ),
        TextField(
          key: const ValueKey('automation-name'),
          controller: _name,
          style: theme.textTheme.titleMedium,
          decoration: const InputDecoration(
            hintText: 'Name this automation',
            isDense: true,
          ),
          onChanged: (value) => _update(_draft.copyWith(name: value)),
        ),
        const SizedBox(height: Insets.sm),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          children: [
            Tooltip(
              message: cannotRun ?? '',
              child: OutlinedButton(
                key: const ValueKey('automation-run-now'),
                onPressed: cannotRun != null
                    ? null
                    : () async {
                        final run = await runAutomationNow(
                          context,
                          ref,
                          original!,
                        );
                        if (run != null && mounted) {
                          setState(() {
                            _runId = run.id;
                            _dry = null;
                          });
                        }
                      },
                child: const Text('Run now'),
              ),
            ),
            OutlinedButton(
              key: const ValueKey('automation-dry-run'),
              onPressed: probe == null
                  ? null
                  : () => setState(() {
                      _runId = null;
                      _dry = {
                        for (final step in dryRunSteps(
                          probe,
                          checkout: checkout,
                          agent: agent,
                        ))
                          step.key: step,
                      };
                    }),
              child: const Text('Dry run'),
            ),
            Tooltip(
              message: blocked ?? '',
              child: FilledButton(
                key: const ValueKey('automation-save'),
                onPressed: blocked != null || _saving ? null : _save,
                child: Text(_draft.isNew ? 'Create' : 'Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _save() async {
    final controller = ref.read(automationControllerProvider);
    final data = ref.read(automationsDataProvider);
    final automation = _draft.toAutomation(
      id: controller.newId(),
      now: controller.now(),
    );
    if (automation == null) return;
    final created = _draft.isNew;
    // Asked on save, not on the switch, so it describes what is armed.
    final before = _draft.original;
    if (automation.enabled && before != null && !before.enabled) {
      final confirmed = await confirmTurnOn(
        context,
        ref,
        automation,
        proposedBy: before.proposedBy,
      );
      if (!mounted) return;
      if (!confirmed) {
        _update(_draft.copyWith(enabled: false));
        return;
      }
    }
    setState(() {
      _saving = true;
      _failure = null;
    });
    try {
      final stored = await data.saveAndWait(automation);
      final issued = created && stored.isWebhook
          ? await data.rotateWebhook(stored.id)
          : null;
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _draft = AutomationDraft.from(stored);
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(created ? 'Created' : 'Saved')));
      if (issued != null) await WebhookSecretDialog.show(context, issued);
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

/// What the Create button says while the readiness list has a cross.
const kNotReadyTooltip = 'Fix what is listed under Ready to run unattended.';

/// The tell step's text until someone writes their own.
const kDefaultTellText =
    'The checks failed:\n\n{{steps.check.output}}\n\nFix them.';

/// The notify step's text until someone writes their own.
const kDefaultNotifyText = '{{automation}} in {{project}}: {{run.status}}';

/// The webhook step's body until someone writes their own.
const kDefaultWebhookBody =
    '{"automation": "{{automation}}", "status": "{{run.status}}"}';

const kDayLetters = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

/// The late policy, said for the editor's question.
String latePolicyWords(AutomationLatePolicy policy) => switch (policy) {
  AutomationLatePolicy.run => 'Run it when Karmashala opens, however late',
  AutomationLatePolicy.ask => 'Run it if it is less than an hour late',
  AutomationLatePolicy.skip => 'Skip it, and show it as missed',
};

/// The agent's own read-only mode, or null when it has none.
PermissionSelection? readOnlySelection(AgentPermissionSupport support) {
  if (!support.isKnown) return null;
  for (final selection in support.selections()) {
    if (support.riskOf(selection) == PermissionRisk.readOnly) return selection;
  }
  return null;
}

/// One line of "Ready to run unattended".
class ReadyRow {
  const ReadyRow(this.ok, this.text, {this.action, this.onAction});

  final bool ok;
  final String text;
  final String? action;
  final VoidCallback? onAction;
}

/// Asks before deleting, and offers to pause instead.
Future<void> confirmDeleteAutomation(
  BuildContext context,
  WidgetRef ref,
  Automation automation,
) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.trash,
        title: 'Delete "${automation.name}"?',
      ),
      content: const BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Text(
          'It won\'t run again, and its steps are forgotten. Its runs stay '
          'in Runs. To stop it for now and keep it, pause it instead.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep it'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop('pause'),
          child: const Text('Pause instead'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop('delete'),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  final controller = ref.read(automationControllerProvider);
  switch (choice) {
    case 'pause':
      controller.setEnabled(automation.id, enabled: false);
    case 'delete':
      controller.delete(automation.id);
      ref.read(automationEditorProvider.notifier).close();
  }
}
