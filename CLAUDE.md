# CLAUDE.md

## Worktree-Only Workflow (Enforced)

**All file modifications are blocked in the main checkout.** A PreToolUse hook (`enforce-worktree.sh`) rejects Edit, Write, and NotebookEdit operations targeting files outside a worktree. There are no opt-outs. Do not use Bash to write files in the main checkout either (e.g., `echo >`, `sed -i`, `tee`, `cp`) — the hook cannot intercept shell commands, so this rule is instruction-enforced.

Before writing any code, create a worktree:

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<name> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

Then work inside `.worktrees/<name>/` for the rest of the session.

## Consumers

`standard_circuit` is consumed by these apps in the rarebit-one workspace:

- `fundbright-web`
- `luminality-web`
- `nutripod-web`
- `sidekick-web`
- `jumpdrive-web` (the control-plane app, formerly `workspace-os`; its `Gemfile`/`Gemfile.lock` live under `control-plane/`, **not** the repo root — a `*/Gemfile` glob misses it, which is how an audit drops this consumer without noticing. Its local checkout is `~/Workspace/rarebit-one/jumpdrive-web` — the directory rename is done; the old `workspace-os` husk was removed 2026-07-14.)

Three consumers live in sibling workspaces — `fundbright-web` in `~/Workspace/fundbright/`, `luminality-web` in `~/Workspace/luminalityai/`, `sidekick-web` in `~/Workspace/sidekick-labs/` — so don't assume every consumer sits beside this repo.

After publishing a new version via `/publish-gem`, roll it out with the workspace-level `/rollout-gem standard_circuit [<version>]` skill (defined at the rarebit-one workspace root, one directory above this repo). The canonical consumer matrix — including version constraints and any non-rubygems sources — lives in that skill's `SKILL.md`; the list here is a summary of it, kept in the bulleted form that `.claude/scripts/check-gem-family-drift.sh` compares against the matrix.

For broader contributor-facing docs, see `AGENTS.md`.
