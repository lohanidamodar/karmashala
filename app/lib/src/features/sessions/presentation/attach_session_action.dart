import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/capabilities/capabilities.dart';
import '../application/session_attach.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';

/// The menus' label for [attachSessionFromUi].
const String kAttachLabel = 'Attach to…';

/// Whether [sessionId] may be attached here: a top-level, unarchived session,
/// on a server that attaches, from a device allowed to. Watched, so a menu
/// built from it moves when the row does.
bool watchCanAttach(WidgetRef ref, String sessionId) {
  ref.watchSession(sessionId);
  final caps = ref.watch(capabilitiesProvider);
  final session = ref.read(sessionsDataProvider).getById(sessionId);
  return caps.attachSessions &&
      session != null &&
      session.parentSessionId == null &&
      !session.isArchived;
}

/// **Attach to…**: [sessionId] becomes the sub-session of a session picked
/// by title, project or agent — on its card, reporting to it when it
/// finishes. Detach undoes it, so nothing is asked twice; a refusal is said
/// in words.
Future<void> attachSessionFromUi(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final child = ref.read(sessionsDataProvider).getById(sessionId);
  if (child == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final compact = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
  final parentId = await showAdaptiveModal<String>(
    context: context,
    title: 'Attach "${child.title}" to…',
    heightFactor: compact ? 1 : 0.8,
    width: DialogWidth.regular,
    builder: (_) => AttachParentPicker(sessionId: sessionId),
  );
  if (parentId == null) return;
  final parent = ref.read(sessionsDataProvider).getById(parentId)?.title;
  String say;
  try {
    await ref.read(sessionAttachProvider)(sessionId, parentId);
    say = '"${child.title}" is under "${parent ?? parentId}" now.';
  } on StateError catch (refusal) {
    say = 'Could not attach it: ${refusal.message}';
  }
  messenger?.showSnackBar(SnackBar(content: Text(say)));
}

/// The sessions [sessionId] may go under, searched by title, agent and
/// project. Those it may not are listed with the reason and cannot be picked.
/// Pops the chosen parent's id.
class AttachParentPicker extends ConsumerStatefulWidget {
  const AttachParentPicker({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<AttachParentPicker> createState() => _AttachParentPickerState();
}

class _AttachParentPickerState extends ConsumerState<AttachParentPicker> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final muted = UiDensity.of(context).muted(Theme.of(context));
    final all = ref.watch(attachParentCandidatesProvider(widget.sessionId));
    final shown = filterAttachParents(all, _query);
    return Column(
      key: const ValueKey('attach-parent-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            0,
            Insets.lg,
            Insets.sm,
          ),
          child: SearchField(
            key: const ValueKey('attach-parent-search'),
            autofocus: true,
            decoration: compactSearchDecoration(
              hintText: 'Search by title, project or agent',
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            0,
            Insets.lg,
            Insets.sm,
          ),
          child: Text(
            'It sits under the session you pick and reports to it when it '
            'finishes. Detach lets it go again.',
            style: muted,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Text(
                      all.isEmpty
                          ? 'There is no other session to attach it to.'
                          : 'No session matches.',
                      key: const ValueKey('attach-parent-empty'),
                      textAlign: TextAlign.center,
                      style: muted,
                    ),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('attach-parent-list'),
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                  itemCount: shown.length,
                  itemBuilder: (context, i) => _ParentRow(
                    candidate: shown[i],
                    onTap: shown[i].allowed
                        ? () => Navigator.of(context).pop(shown[i].id)
                        : null,
                  ),
                ),
        ),
      ],
    );
  }
}

/// One session in the picker: its title, agent · project, and why it cannot
/// be the parent when it cannot.
class _ParentRow extends StatelessWidget {
  const _ParentRow({required this.candidate, required this.onTap});

  final AttachParentCandidate candidate;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final line = [?candidate.agentName, ?candidate.projectName].join(' · ');
    final refusal = candidate.refusal;
    return InkWell(
      key: ValueKey('attach-parent-row:${candidate.id}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.target),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                candidate.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: refusal == null ? null : scheme.onSurfaceVariant,
                ),
              ),
              if (line.isNotEmpty)
                Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              if (refusal != null)
                Text(
                  refusal,
                  key: ValueKey('attach-parent-refusal:${candidate.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
