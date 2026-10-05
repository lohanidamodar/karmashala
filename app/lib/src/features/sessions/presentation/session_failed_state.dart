import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_notifications/attention.dart' show describeFollowUp;
import 'package:karmashala_session/events.dart' show FollowUpReason;
import 'package:karmashala_session/session.dart' show SessionStatus;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/session_launcher.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';

/// Where the transcript of a session that ended in error would be: what its
/// follow-up recorded, and a way to start it again.
class SessionFailedState extends ConsumerStatefulWidget {
  const SessionFailedState({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionFailedState> createState() =>
      _SessionFailedStateState();
}

class _SessionFailedStateState extends ConsumerState<SessionFailedState> {
  bool _retrying = false;
  String? _refusal;

  Future<void> _retry() async {
    setState(() {
      _retrying = true;
      _refusal = null;
    });
    try {
      await ref.read(sessionLauncherProvider).resumeAtServer(widget.sessionId);
    } on Object catch (error) {
      if (mounted) setState(() => _refusal = '$error');
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final followUp = ref
        .read(followUpsDataProvider)
        .open()
        .where(
          (f) =>
              f.sessionId == widget.sessionId &&
              f.reason == FollowUpReason.endedInFailure,
        )
        .firstOrNull;
    final detail = followUp == null
        ? 'The session stopped in error before anything reached its '
              'transcript.'
        : describeFollowUp(followUp);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(Insets.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.warningCircle,
                      size: Chrome.iconHero,
                      color: scheme.error,
                    ),
                    const SizedBox(height: Insets.sm),
                    Text(
                      'Ended in error',
                      style: theme.textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: Insets.xs),
                    SelectableText(
                      detail,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Insets.md),
                    FilledButton(
                      onPressed: _retrying ? null : _retry,
                      child: const Text('Retry'),
                    ),
                    if (_refusal case final refusal?) ...[
                      const SizedBox(height: Insets.sm),
                      SelectableText(
                        refusal,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [otherwise], unless session [sessionId] ended in error: then what it left.
class SessionEmptyOrFailed extends ConsumerWidget {
  const SessionEmptyOrFailed({
    required this.sessionId,
    required this.otherwise,
    super.key,
  });

  final String sessionId;
  final Widget otherwise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watchSession(sessionId);
    final status = ref.read(sessionsDataProvider).getById(sessionId)?.status;
    return status == SessionStatus.failed
        ? SessionFailedState(sessionId: sessionId)
        : otherwise;
  }
}
