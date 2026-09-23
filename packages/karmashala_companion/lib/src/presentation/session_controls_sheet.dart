import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/companion_providers.dart';
import 'companion_chrome.dart';
import 'companion_states.dart';

/// Opens the model and permission pickers for [sessionId].
Future<void> showSessionControls(BuildContext context, String sessionId) =>
    companionSheet<void>(
      context,
      title: 'Model & permissions',
      children: [SessionControls(sessionId: sessionId)],
    );

/// A session's model and permission mode, chosen from the phone and applied
/// the way the desktop's own chips apply them — live where the agent allows.
class SessionControls extends ConsumerStatefulWidget {
  const SessionControls({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionControls> createState() => _SessionControlsState();
}

class _SessionControlsState extends ConsumerState<SessionControls> {
  RemoteSessionOptions? _options;
  String? _error;
  String? _said;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final options = await ref
          .read(companionGatewayProvider)
          .sessionOptions(widget.sessionId);
      if (mounted) setState(() => _options = options);
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error));
    }
  }

  Future<void> _choose({
    String? modelId,
    bool modelDefault = false,
    String? permissionId,
    bool permissionDefault = false,
  }) async {
    setState(() {
      _busy = true;
      _said = null;
      _error = null;
    });
    try {
      final outcome = await ref
          .read(companionGatewayProvider)
          .configureSession(
            widget.sessionId,
            modelId: modelId,
            modelFollowsDefault: modelDefault,
            permissionId: permissionId,
            permissionFollowsDefault: permissionDefault,
          );
      if (!mounted) return;
      setState(() => _said = outcomeSentence(outcome));
      await _load();
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    final canChange = ref
        .read(companionGatewayProvider)
        .capabilities
        .has(Capability.sendPrompt);
    if (options == null) {
      return Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: _error == null
            ? const Center(child: CircularProgressIndicator())
            : CompanionInlineError(_error!),
      );
    }
    final enabled = canChange && !_busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (options.models.isNotEmpty) ...[
          _heading('Model'),
          _row(
            label: 'Desktop default',
            summary: options.modelDefaultLabel ?? 'The agent chooses',
            selected: options.modelId == null,
            onTap: enabled ? () => _choose(modelDefault: true) : null,
          ),
          for (final model in options.models)
            _row(
              label: model.label,
              summary: model.summary,
              selected: options.modelId == model.id,
              onTap: enabled ? () => _choose(modelId: model.id) : null,
            ),
        ],
        if (options.permissions.isNotEmpty) ...[
          _heading('Permission mode'),
          _row(
            label: 'Desktop default',
            summary: options.permissionDefaultLabel ?? '',
            selected: options.permissionId == null,
            onTap: enabled ? () => _choose(permissionDefault: true) : null,
          ),
          for (final mode in options.permissions)
            _row(
              label: mode.label,
              summary: mode.summary,
              selected: options.permissionId == mode.id,
              onTap: enabled ? () => _choose(permissionId: mode.id) : null,
            ),
        ],
        if (options.models.isEmpty && options.permissions.isEmpty)
          _note('This session has nothing the desktop can change.'),
        if (!canChange)
          _note(
            'This phone was not granted send_prompt, so it can look but not '
            'change these.',
          ),
        if (_said case final said?) _note(said),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: CompanionInlineError(error),
          ),
      ],
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
    child: CompanionSectionHeader(text),
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _row({
    required String label,
    required String summary,
    required bool selected,
    required VoidCallback? onTap,
  }) => ListTile(
    title: Text(label),
    subtitle: summary.isEmpty ? null : Text(summary),
    trailing: selected ? Icon(AppIcons.check, semanticLabel: 'Chosen') : null,
    selected: selected,
    enabled: onTap != null || selected,
    onTap: selected ? null : onTap,
  );
}

/// What a change did to the session running on the desktop, in one sentence.
String outcomeSentence(RemoteConfigureOutcome outcome) => switch (outcome) {
  RemoteConfigureOutcome.now => 'Switched now, in the running session.',
  RemoteConfigureOutcome.afterTurn =>
    'Switches when the agent finishes this turn.',
  RemoteConfigureOutcome.pickerOpened =>
    'The agent opened its own picker on the desktop — choose it there to '
        'switch now. It is also saved for the next launch.',
  RemoteConfigureOutcome.recorded =>
    'Saved — applies the next time this session runs.',
};
