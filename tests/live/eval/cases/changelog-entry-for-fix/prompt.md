A fix has landed that keeps the underlying error when isolated Terminal runtime
preparation fails, instead of showing only generic Docker advice.

Add the matching entry to the `### Fixed` list in the `## [Unreleased]` section
of `CHANGELOG.md`. Say that redacted error details are now shown when Terminal
runtime preparation fails, and link to
`docs/isolated-terminal.md#if-preparation-fails`.

Change nothing else, and do not commit.
