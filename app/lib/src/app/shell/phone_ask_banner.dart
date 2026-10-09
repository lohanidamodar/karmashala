import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/explorer/application/session_context.dart';
import '../../features/sessions/application/session_status_providers.dart';
import 'reveal_session.dart';

/// **Another session needs you** (Stage 2 step 5): one line under the phone's
/// session page app bar, from the same feed as the needs-you badges — the
/// phone's stand-in for the desktop's ask toasts. It answers nothing: *Open*
/// goes to the session, and × hides this ask until that session asks again.
class PhoneAskBanner extends ConsumerStatefulWidget {
  const PhoneAskBanner({super.key});

  @override
  ConsumerState<PhoneAskBanner> createState() => _PhoneAskBannerState();
}

class _PhoneAskBannerState extends ConsumerState<PhoneAskBanner> {
  /// Asks closed by the user, by session and when its wait began, so the next
  /// ask from the same session shows again.
  final _dismissed = <(String, int?)>{};

  (String, int?) _keyOf(String openId) => (
    openId,
    ref
        .read(sessionStatusLookupProvider)(openId)
        ?.waitingSince
        ?.millisecondsSinceEpoch,
  );

  @override
  Widget build(BuildContext context) {
    final waiting = ref.watch(needsYouProvider);
    final onScreen = ref.watch(panelSessionIdProvider);
    final keys = {
      for (final openId in waiting.keys)
        if (openId != onScreen) openId: _keyOf(openId),
    };
    // Forget dismissals of asks that are over.
    _dismissed.removeWhere((key) => !keys.containsValue(key));
    final shown = [
      for (final MapEntry(key: openId, value: key) in keys.entries)
        if (!_dismissed.contains(key)) openId,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();

    final first = shown.first;
    final source = waiting[first]!;
    final more = shown.length - 1;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final attention = SemanticColors.of(context).attention;
    final density = UiDensity.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: more > 0
          ? '${source.label} and $more more need you'
          : '${source.label} needs you',
      child: Material(
        color: tones.attentionSurface,
        child: Container(
          key: const ValueKey('phone-ask-banner'),
          constraints: const BoxConstraints(minHeight: Touch.target),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tones.attentionEdge)),
          ),
          padding: const EdgeInsetsDirectional.only(start: Insets.md),
          child: Row(
            children: [
              Icon(AppIcons.shield, size: Touch.icon, color: attention),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: ExcludeSemantics(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: source.label),
                        TextSpan(
                          text: more > 0
                              ? ' and $more more need you'
                              : ' needs you',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: density.rowTitle(theme, strong: true),
                  ),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(Touch.target, Touch.target),
                ),
                onPressed: () => revealSession(
                  ref.container,
                  openId: first,
                  imported: source.imported,
                ),
                child: const Text('Open'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                iconSize: Touch.icon,
                color: scheme.onSurfaceVariant,
                icon: const Icon(AppIcons.x),
                onPressed: () => setState(() => _dismissed.add(_keyOf(first))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
