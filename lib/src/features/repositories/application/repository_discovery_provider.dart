import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository_discovery_service.dart';

/// Provides the repository discovery service. Overridden in tests with a fake.
final repositoryDiscoveryServiceProvider = Provider<RepositoryDiscoveryService>(
  (ref) => const LocalRepositoryDiscoveryService(),
);
