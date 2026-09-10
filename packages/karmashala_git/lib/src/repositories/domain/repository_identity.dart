import '../../git/domain/remote_repo.dart';

/// The canonical name of the repository an `origin` URL points at —
/// `github.com/popupbits/karmashala` — or null when the URL names nothing a
/// second checkout could agree with.
///
/// A `repositories` row is a location, and two locations can be one repository;
/// this is the key that says which. Read off `origin` only, through
/// [RemoteRepo.parse]: scheme, credentials and an ssh port dropped, an explicit
/// http(s) port kept, `.git` stripped, and the whole thing lower-cased. **Null is
/// a real answer**, so nothing may group on it without a path-only fallback.
String? canonicalRepositoryId(String? originUrl) {
  final remote = RemoteRepo.parse(originUrl);
  return remote == null ? null : '${remote.host}/${remote.slug}'.toLowerCase();
}
