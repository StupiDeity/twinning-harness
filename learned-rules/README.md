# learned-rules/

Each subdirectory under this path is keyed by `PROJECT_SLUG` — the value
set under `project.slug` in a target's `.pipeline-config/config.json`,
frozen at first setup. Resolution happens in `bin/render-prompt.sh:141`
(per-slug `project-profile.md` for the profile addendum) and
`bin/render-prompt.sh:214` (`{learned_rules_dir}` substitution into stage
prompts).

Current slugs:

- `harness/` — the harness-self target (this repo, when its own pipeline
  drives changes to itself).
- `twinning/` — the Twinning desktop app, the original target this harness
  was built for.

A subdirectory holds one `project-profile.md` plus zero-or-more
`<stage>.md` files that the retrospective agent appends to dispatched
stage prompts. Do not delete a slug directory unless you are certain no
operator runs the harness against that target — the retrospective-agent
rule history is non-recoverable from git short of a revert.
