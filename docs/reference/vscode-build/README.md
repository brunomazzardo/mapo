# VS Code build: frozen references

The files in this folder are frozen copies from the VS Code build of Mapo: branch `mapo` at commit `a7bc6c9e73e` (2026-09-28), checked out at `~/code/mapo`. They describe how the old app behaved. They are not native requirements. Where they disagree with [REQUIREMENTS.md](../../REQUIREMENTS.md), [ARCHITECTURE.md](../../ARCHITECTURE.md) or [PROTOCOL.md](../../PROTOCOL.md), those documents win. [FEATURE-MAP.md](../../FEATURE-MAP.md) maps every old feature and file to its native status.

Do not edit these files. If the frozen branch gets a blocker fix later, record it in FEATURE-MAP.md instead of copying the files again.

## Files

| File | Copied from | What it is | Use it for |
|---|---|---|---|
| [COMMANDS.md](COMMANDS.md) | `docs/mapo/COMMANDS.md` | The command API of the VS Code build: every `mapo.*` command, CLI verb and MCP tool, their JSON arguments and results, guards, the status vocabulary and the CLI output rules | R-CTL-2: verbs, flags and JSON shapes that also exist in native stay compatible |
| [FEATURE-RESEARCH.md](FEATURE-RESEARCH.md) | `docs/mapo/FEATURE-RESEARCH.md` | Ranked feature research from 60 days of the user's Claude transcripts and shell history (2026-09-25), with suggestion IDs A1 to F2 | Why a feature exists; the LATER backlog in REQUIREMENTS §6 |
| [IMPLEMENTATION-ORDER.md](IMPLEMENTATION-ORDER.md) | `docs/mapo/IMPLEMENTATION-ORDER.md` | The approved delivery order 0 to 9 for the VS Code build, the "commands are the feature boundary" rule, and where each research suggestion landed | Scope boundaries, such as saved setups versus conversation resume |
| [OVERNIGHT-PROGRESS.md](OVERNIGHT-PROGRESS.md) | `docs/mapo/OVERNIGHT-PROGRESS.md` | Checkpoint log of the 2026-09-25/26 overnight run and the user's follow-ups: bugs reproduced, fixes, acceptance evidence, limits | The behavior contracts in REQUIREMENTS §8 and the proposed additions in FEATURE-MAP §6 |
| [SKILL.md](SKILL.md) | the `mapoSkill` template string in `src/vs/workbench/contrib/mapo/common/mapoSkill.ts`, lines 7 to 51, front matter kept | The agent skill the VS Code build served through `mapo skill`, the MCP resource `mapo://skill` and managed Claude tabs | The starting text for the native skill (T3.6). It mentions server, setup, repo, action and mprocs verbs that native v1 does not have. |

## Reading these files

- Words that changed in native: tab kinds `terminal` and `claude` are `shell` and `agent`; `MAPO_CONTROL_TOKEN` is `MAPO_TOKEN`; a "window" is an instance; command ids such as `mapo.tab.create` are protocol methods such as `tab.create`; "server tabs" are managed servers, which are LATER (R-SRV-6). FEATURE-MAP §1 has the full list.
- Relative links inside the copies, such as `HANDOFF.md`, `ACTIONS-DELIVERY.md`, `screenshots/...`, `evidence/...` and `../superpowers/...`, point to files that were not copied. They resolve on the branch under `docs/mapo/`:

  ```sh
  git -C ~/code/mapo-native show a7bc6c9e73e:docs/mapo/HANDOFF.md
  git -C ~/code/mapo-native ls-tree -r --name-only a7bc6c9e73e -- docs/mapo/evidence docs/mapo/screenshots
  open ~/code/mapo/docs/mapo/screenshots/overnight/31-claude-readable-menu.png
  ```

- Other old documents that stay on the branch: `docs/mapo/HANDOFF.md`, the `*-DESIGN.md` and `*-DELIVERY.md` files, `DELIVERY-1-REVIEW.md`, `docs/mapo/evidence/*.json`, 111 screenshots under `docs/mapo/screenshots/`, and the original spec and plans under `docs/superpowers/`.
- `~/code/mapo` is the user's daily driver. Read it with `git show` from this worktree or with `rg`; never edit, build or check out anything there. FEATURE-MAP §7 has more commands.

## Checking the copies

The four Markdown copies are byte-identical to the branch, and SKILL.md is the template text with nothing added:

```sh
cd ~/code/mapo-native/docs/reference/vscode-build
for f in COMMANDS.md FEATURE-RESEARCH.md IMPLEMENTATION-ORDER.md OVERNIGHT-PROGRESS.md; do
  git -C ~/code/mapo-native show "a7bc6c9e73e:docs/mapo/$f" | cmp - "$f" && echo "$f ok"
done
git -C ~/code/mapo-native show a7bc6c9e73e:src/vs/workbench/contrib/mapo/common/mapoSkill.ts \
  | sed -n '7,51p' | sed '1s/^export const mapoSkill = `//' | cmp - SKILL.md && echo "SKILL.md ok"
```
