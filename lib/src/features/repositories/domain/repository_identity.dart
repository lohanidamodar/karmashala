import '../../git/domain/remote_repo.dart';

/// The canonical name of the repository an `origin` URL points at —
/// `github.com/popupbits/karmashala` — or null when the URL names nothing a
/// second checkout could agree with.
///
/// **A `repositories` row is a location, and two locations can be one
/// repository.** Sixty-nine rows on the owner's machine are worktrees and
/// clones of a handful of actual repositories, and nothing in `(id, projectId,
/// name, path, createdAt)` could say which. This is the missing key: every
/// checkout of one repository derives the same string, and every checkout of a
/// different one derives a different string.
///
/// **Read off `origin`, and only off `origin`.** The remote is the one fact two
/// unrelated clones share and two unrelated directories do not. It is parsed by
/// [RemoteRepo.parse], which already knows every spelling git accepts, so the
/// normalisation is one rule rather than a second parser drifting from the one
/// the delivery strip's links are built from:
///
/// * the **scheme** is dropped — `git@`, `https://`, `ssh://` and `git://` are
///   four ways to reach one repository;
/// * **credentials** are dropped — a token in the URL is this machine's, not
///   the repository's;
/// * an **ssh port** is dropped and an explicit http(s) port kept, because the
///   first is a transport detail and the second is part of the address;
/// * a trailing **`.git`** and any trailing slash go;
/// * and the whole thing is **lower-cased**. Host case never mattered; owner
///   and name are folded too because GitHub and GitLab both resolve them
///   case-insensitively, so a key that told `PopupBits/app` from
///   `popupbits/app` would fail at the one job it has.
///
/// **Null is a real answer and the common one to plan for**: a `git init` with
/// no remote, a `file://` URL, a plain local path, a directory that is not a
/// repository at all. Nothing may group on this without degrading to today's
/// path-only behaviour when it is null.
String? canonicalRepositoryId(String? originUrl) {
  final remote = RemoteRepo.parse(originUrl);
  return remote == null ? null : '${remote.host}/${remote.slug}'.toLowerCase();
}
