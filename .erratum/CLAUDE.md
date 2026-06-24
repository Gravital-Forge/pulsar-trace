# Authoring Erratum docs

This directory is maintained per the Erratum framework (see `erratum.md`). Conventions for the
Markdown itself:

- **Formatting is enforced by pre-commit** — `mdformat` (`--wrap=100 --number --end-of-line=lf`,
  with `mdformat-gfm`) plus `markdownlint-cli2` (config in the repo-root `.markdownlint.json`, which
  enforces `MD013` line length 150). Run `pre-commit run --all-files` before committing.
- **Keep tables narrow.** `MD013` checks table rows against the 150-column limit and `mdformat`
  cannot wrap inside a table cell. If a table would exceed the limit — typically a
  "Requirements satisfied" row carrying a long file/symbol list — **rewrite it as a bullet list**
  instead; list items wrap to 100 columns and stay within the limit. Reserve tables for genuinely
  tabular, short-celled data such as the traceability matrix.
