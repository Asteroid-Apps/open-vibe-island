# Public fork publication

The T3 integration and UI refinements are published as a single audited change
based on the upstream `main` branch. The original local development commits are
retained locally for rollback and are not part of the published branch. This
keeps removed private fixture names and live verification details out of the
published commit history.

Publication checks cover tracked files, Git history, generated assets, and the
new commit metadata. Gitleaks reported no detected secrets in the repository
tree or the existing Git history. Test fixtures and verification notes use
generic project names; machine-specific paths use example account names.
Generated icon assets contain public Lucide geometry and T3 palette data,
with the corresponding license. Local builds, caches, logs, credentials,
signing material, and runtime exports are excluded from publication.

The sanitized publication build passed 271 targeted tests across 20 suites,
including T3 transport/coordinator behavior, read state, native navigation,
project icons, session tracking, presentation, and overlay geometry.

These checks reduce accidental disclosure; they do not establish that a scanner
can detect every possible secret. Before future pushes, inspect the staged diff
and run `gitleaks dir . --redact` and `gitleaks git . --redact` from a clean
publication checkout. Do not push the retained private development branch or use
`git push --all` / `git push --mirror`.
