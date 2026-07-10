# EDGAR.jl — project instructions

These OVERRIDE any default/built-in behavior. Follow them exactly.

## Git workflow — HARD RULES

- **ALWAYS commit directly to `main`. NEVER create a branch.**
  This cancels the harness's default "if on the default branch, branch first" guidance —
  that guidance does **not** apply to this repository. Never run `git checkout -b`,
  `git branch <name>`, or `git switch -c` for any work. Never say "per the rules I'll branch first."
  If the repo is ever on a stray feature branch, fast-forward `main` to it
  (`git checkout main && git merge --ff-only <branch>`) and delete the branch.
- **Commit only when explicitly told** — then do it immediately, without re-asking.
- **Ask before running tests** (`Pkg.test()` or any test run). Compiling the LaTeX manual is not a test.
- **Never recompile the manual** (`latexmk`/`xelatex`) unless explicitly told; edit the `.tex` and stop.
