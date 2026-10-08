// What shows with no apps yet, and while the first read loads.

part of '../stores_tab_view.dart';

class _NothingToShow extends StatelessWidget {
  const _NothingToShow({required this.filter});

  final StoresFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = switch (filter) {
      StoresFilter.attention => 'Nothing needs you right now.',
      StoresFilter.inProgress => 'No release is in review or rolling out.',
      StoresFilter.newReviews => 'No reviews this week.',
      StoresFilter.all => 'No apps.',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxl),
      child: Column(
        children: [
          Icon(
            AppIcons.checkCircle,
            size: Chrome.iconHero,
            color: SemanticColors.of(context).idle,
          ),
          const SizedBox(height: Insets.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The shape of the overview while the stores are read for the first time.
class _Skeletons extends StatelessWidget {
  const _Skeletons({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Reading the stores',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.lg),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kStoresContentMaxWidth),
            child: const _CardGrid.skeletons(),
          ),
        ),
      ),
    );
  }
}
