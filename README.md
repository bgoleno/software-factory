# software-factory

Starts a team of Claude Code sessions for a software project. Each seat (engineering manager, tech
lead, engineers, QA, security, or whatever you define) runs in its own persistent tmux session, is
told its role, works in its own git worktree, and can message the other seats.

The team is defined in one YAML file per project, so different projects can have different teams,
prompts, models and storage.

## Requirements

Moved to [Commands: Requirements](docs/commands.md#requirements).

## Use

Moved to [Commands](docs/commands.md): [the commands](docs/commands.md#the-commands), [which team file](docs/commands.md#which-team-file) and [throwaway teams](docs/commands.md#throwaway-teams).

## The iTerm view

Moved to [Commands: The iTerm view](docs/commands.md#the-iterm-view).

## Right-sizing

Moved to [Right-sizing a team](docs/right-sizing.md).

## The team file

Moved to [The team file](docs/team-file.md).

## New worktrees

Moved to [The team file: New worktrees](docs/team-file.md#new-worktrees).

## The factory plugin

Moved to [The factory plugin](docs/plugin.md).

## Issues first

Moved to [How work is tracked: Issues first](docs/workflow.md#issues-first).

## How seats talk

Seats message each other with Claude Code's
[cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging): `SendMessage` to a
session name, and `ListAgents` to see which sessions are up. `up` starts every seat with `-n <session>`,
so the names are the roster's session column, and the shared prompt (`roles/common.md`) tells seats to
use them. A message arrives between tool calls without interrupting a running tool. It cannot answer a
permission prompt or change settings, and bursts and loops are throttled. A seat waiting on another can
ask for one notice when that seat next goes idle (`notify_when_idle`) instead of polling it.

Session names are not authenticated: a sender's name is a claim, not an identity. Claude Code's own
held-message notice shows the sender as a verified process id and the name it claims ("peer claims
name"). Every Claude session on the machine, other teams' seats included, can message a seat, and any
local process can start a session under a seat's name. A delivered message carries the sender's address
in `from` and its session name in `from-name`. The prompt tells seats to act only on a `from-name` that
exactly matches a roster name, and to report any other sender, or two sessions sharing a roster name, to
the EM. That guards against mistakes, not impersonation, which is the same limit as for `say` and the
pane (see [Safety](#safety)).

### Which messages are held

The launcher sets no `crossSessionInbound`, so Claude Code decides per message from the two sessions'
permission modes. `bypassPermissions` is one class, and every other mode (`auto`, `acceptEdits`,
`dontAsk`, `default`) is the other.

| From, to | What happens |
|---|---|
| Seat to seat, both in one class (one `permission_mode` for every seat) | Delivered. |
| Seat to seat, different classes (a role with its own `permission_mode`) | Held. An approval dialog opens in the receiver's pane, and if nobody answers it the message is dropped after `dialogExpiry` (5 minutes by default). In an unattended team, that means it is lost. `check` warns when the seats fall into both classes, naming the roles in each. |
| The owner's own Claude session to a seat | The same rule: delivered when both are in one class, held otherwise. |
| Any other Claude session on the machine to a seat | The same rule. |
| The owner typing into an attached seat, or `say` | Not a cross-session message, so it is never held. |

The sender gets a notice when a message is held, refused or expires. The prompt tells a seat never to
resend the content with `say`: a refusal is the receiver's decision, and a hold waits for a human in
that pane. While a message to a seat is held, the sender does not use `say` to that seat at all, because
its pane is showing the approval dialog; it waits for the notice that the message was delivered or
expired. A refused or expired message is reported to the EM with `SendMessage`, or with `say em` if the
EM was the receiver or the report was refused or expired too, and never with `say em` while a hold to
the EM is pending. `say` is the seats' fallback only for a running seat that `ListAgents` does not show.

To change the default, set `crossSessionInbound` to `accept`, `hold` or `refuse`. It is read from managed
settings, then the `--settings` file, then user settings, and the first value found applies. A project or
local value applies only when it is stricter. `accept` in user settings delivers every message to every
session you run, from any local session, so think twice before using it with bypass seats. The team file
has no key for it. `dialogExpiry` (`60s`, `5m`, `10m` or `never`) can be set only in user or managed
settings.

### `say`

`say` is how the owner and scripts reach a seat, and the seats' fallback for a seat that `SendMessage`
cannot reach. It types a message into the seat's tmux pane by bracketed paste, then presses Enter. It
types only when the bottom of the seat's screen is Claude Code's input box, empty or showing only one
dim line (a hint or a suggested prompt), and presses Enter only when the box then holds just the
message. The `[from <role>]` label goes in as a paste of its own, before the message
([#150](../../issues/150)). Claude Code hands a long paste, one it shows as `[Pasted text #N]`, to the
seat inside `<pasted_content>` tags, and seats doubted a label inside them. A paste as short as the
label stays plain text, outside the tags. `say` pastes the message only once the box holds just the
label, so a message never goes in without it. Anything else fails closed, with a reason:

- a seat that is not running claude (the text would run as a shell command);
- any dialog, prompt or menu, known or not, the held-message approval dialog included ("screen not
  recognised as ready"), where the Enter would pick an answer;
- an input box that already holds text (someone typing, or an earlier message that was not sent);
- a pane in copy mode (someone scrolling);
- Claude Code's diff panel notice ("Resize your terminal to at least 110 columns to show the diff
  panel") in a pane of 13 rows or fewer, where it pushes the end of the input box off the screen.
  `say` grows such a pane and checks again (below), so this shows only if that fails. With 16 rows
  or more the notice is harmless (at 14 or 15 only a one-line message fits). Widen the pane to 110
  columns, give it 16 rows or more, or close the diff panel in the seat;
- a screen tmux cannot read;
- another `say` typing into the same seat that has not finished within 8 seconds. One `say` at a time
  types into a seat (an `flock` on `.state/<team>/say/<role>.lock`, released when that `say` exits,
  however it ends), so two messages never mix in one box. Anything other than a plain file at that
  path (a FIFO, a symlink) is refused at once: remove it.

Attach to the seat, deal with it, and send again. After the paste, `say` sends Enter only when the box
holds the message and nothing else: the whole message (whitespace aside, since the box wraps it), its
label and one placeholder, or the end of a message taller than the box (below). If it does not, if
the box does not hold just the label after the label's paste (then the message is not pasted at all),
or if the message's paste fails after its label's, no Enter is sent and
the text stays in the box, where it goes out with the next Enter; `say` says so, and says why: the
screen no longer ends with the box, dim text was drawn next to the message, the box shows fewer rows
than it can and not just the message (as when someone typed after it), too little of the message's
end is visible (under 40 characters, as with short last lines in a narrow pane), or the box does not
end with the message.

**Short panes ([#84](../../issues/84)).** A seat's pane takes the size of the iTerm pane attached to
it, and the team view makes them small: 89x13 with ten seats on a 77-row display, about 10 rows with
twelve. Under 110 columns a seat whose diff panel is open draws the notice above its box, which at 13
rows or fewer pushes the box off the screen; under 12 rows a paste grows the box past the bottom, and
even a multi-line paste collapses to a placeholder (all measured on 2.1.316). Most messages still fit,
so `say` runs its checks at the pane's own size. Only when one refuses (before the paste, or after it,
with the text already in the box) in a window under 110 columns or under 12 rows does `say` grow the
window to 220x50 (the size seats run at detached, where the checks above were measured and verified
live), run that check again there, and go on only if it passes; then it puts back exactly the size and
the window's `window-size` option it found. A window is grown at most once per message, and a window of
110x12 or more is never resized. So the view flashes only for a `say` that would otherwise be refused:
while the window is grown, the seat's pane shows a clipped part of the bigger window and Claude Code
redraws twice, for about a second. The traps put the window back however `say` ends, except SIGKILL;
a `say` killed that way can leave the window at 220x50 with `window-size` set to `manual`, and
`tmux set-option -w -u -t '=<session>:' window-size` puts it back to following the iTerm pane.
A message taller than the box (up to 800 characters and 3 lines, not counting its label; a longer
paste shows as a `[Pasted text #N]` placeholder) scrolls it, so only the message's end is visible. `say` then sends it only when
the box is full (floor((pane rows - 10) / 2) rows, at least 3) and its visible text is the message's
last 40 or more characters. Its label has scrolled out of view by then, which is why `say` checks the
label alone, before it pastes the message. Two gaps remain: if someone starts typing in the moment
between `say`'s empty-box check and the paste, and the message scrolls that text out of view, it goes
out with the message; and if the label is cleared from the box (Ctrl-C, Esc) in the moment between
`say`'s check of it and the message's paste, the message goes out without it.
The input box is recognised as Claude Code 2.1.316 draws it, so a CLI update that changes it makes `say`
refuse every seat until `factory.sh` is updated. A refused message is logged as NOT-DELIVERED. Messages
are labelled `[from <role>]`, and the owner's are `[from owner]`. The label is set by the sender (from
`TEAM_ROLE`, or `owner` when it is unset) and is not authenticated. When `TEAM_ROLE` is unset, `say`
run from inside a seat (found from the terminals of the processes that started it) is labelled with
that seat's role, never `[from owner]`; this stops a mislabel by accident, and the labels are still
not authenticated ([#29](../../issues/29)). When it cannot tell, `say` refuses rather than guess: when
`ps` cannot read its process or one of its ancestors, when its walk up them stops at 100 processes
before pid 1 ([#130](../../issues/130)), when tmux cannot list its panes, when it runs
inside a seat of another team on the same tmux server (any session `up` started, which sets
`TEAM_ROLE`), or when a tmux server other than the one `say` addresses is among its ancestors. The last
is a pane of another server, whose seats `say` cannot see ([#115](../../issues/115)). It refuses a seat of
any team on any other server, and the owner's own pane on such a server too. From a terminal outside tmux
the owner is still `[from owner]` (`TEAM_ROLE=owner` is refused). A background job that outlives the
command that started it, or a command a seat runs in a new tmux session on the server `say` addresses, is
not caught and is labelled `[from owner]` (the comment above `caller_seat` in `factory.sh` lists every such
way). A seat cannot `say` to itself. A `TEAM_ROLE` that is set must be one of the team's role ids, or
`live-test`: `say` refuses any other value, and the reserved `owner` and `launcher`, sending no keys and
logging NOT-DELIVERED. It refuses an empty or whitespace-only message the same way, before any tmux
command, for one seat and for `all` ([#157](../../issues/157)); with `TEAM_ROLE` unset, that refusal is
logged under the sender `?`.

`live-test` is the driver label. `test/live-env.sh run` sets `TEAM_ROLE=live-test`, so a live test that a
seat drives sends as `[from live-test]`, never as `[from owner]`. No role id can be `live-test`, since role
ids hold no hyphen. `say` refuses it when it addresses the default tmux server, where the real team runs,
even with `--default-socket`.
It works that out from `TMUX` and `TMUX_TMPDIR`, before any tmux command. The limit: a real team the owner
runs on a tmux server other than the default one is not told apart from a test team, and can receive
`[from live-test]`.

### The kickoff

`up` gives each seat its kickoff (`kickoff` in the team file, or a role's own) as its first message,
labelled `[from launcher]`. Seats know the owner's voice as input with no label, so without the label
a team file's kickoff would read as the owner typing, at every start, to anyone who can edit the team
file. The shared prompt (`roles/common.md`) tells seats a `[from launcher]` message is team
configuration: it can say how to start, but it is never an owner instruction or approval, and the
EM's prompt never takes one as a merge instruction. `check` shows each seat's kickoff with its label.
`say` never sends as `launcher` (it refuses `TEAM_ROLE=launcher`, and `launcher` is not a valid role
id), and a kickoff may not contain a `[from …]` label of its own. For the same reason `owner` is not a
valid role id either: a seat named `owner` would send `[from owner]`, the owner's own label. Like every label, it is not
authenticated (#29): it keeps the kickoff from looking like owner input, nothing more.

### The message log

`.state/<team>/messages.log` records every `say` with its delivery outcome, and every `SendMessage` a seat
sends (#39), through a hook in each seat's generated settings.

Each `say` (`say all` included) appends exactly one line of five tab-separated fields: the local time
(`2026-10-30T14:05:09`), the sender (`TEAM_ROLE`, which is a role id or `live-test`; the seat `say` ran inside; `owner`; or `?` when `TEAM_ROLE` is unset and
`say` refused because it could not tell whether it ran inside a seat), the recipient (a role id or `all`),
`delivered` or `NOT-DELIVERED`, and the message as typed, without its `[from <role>]` label. The
sender and the message are escaped so the record stays on one line and holds no terminal control
codes: a backslash is written `\\`, a newline `\n`, a carriage return `\r`, a tab `\t`. Every other C0
control (below U+0020), DEL, C1 control (U+0080 to U+009F) and bidi embedding, override or isolate
(U+202A to U+202E, U+2066 to U+2069) is written as its UTF-8 bytes, each as `\xHH` (two upper-case hex
digits): U+009B is `\xC2\x9B`. Other text, such as `é` or `✓`, is written as it is. A message that is
not valid UTF-8 has every byte from 0x80 up written as `\xHH`. If the escaping itself fails, the field
reads `<log_field failed>`. The escaping is reversible: `printf '%b' "<field>"` in bash gives back
the original text.

`say` writes this line before it prints anything about the delivery, such as why a message was not
delivered (#128). A write to a terminal or a pipe can fail (with EINTR under heavy load, into a closed
stderr, or into a pipe whose reader has gone), and the failure ends `say`; written first, the record is
kept all the same. If the line itself cannot be appended, `say` still prints its reason, then says the
record could not be written and whether the message was delivered (so that a delivered message is not
sent again), and exits with status 1.

The log is never written through a link ([#194](../../issues/194)). When `messages.log` is a symlink, a
FIFO or a hard link (a file with a second name), `say` delivers nothing and writes no line: it prints
why, says the record could not be written, and exits with status 1. Only a seat could put one there;
remove it by its exact path. `lib/log_message.sh` (below) opens the log without following a symlink and
writes only to a regular file with one link, so there it costs that line.

Each `SendMessage` from a seat appends one line in the same format, written by `lib/log_message.sh`, a
`PostToolUse` and `PostToolUseFailure` hook on `SendMessage` in every seat's settings:

- the sender is the seat's role id, and the message is the text it sent, escaped as above. A message
  that is not a string is written as its JSON text. A lone UTF-16 surrogate escape in the hook input
  (`\ud800` with no low half after it, or a low half alone), which Ruby's JSON parser refuses, is read
  as U+FFFD (`�`); a valid pair is kept;
- the recipient is a role id when the `to` names a roster seat's session (`sf-tl`, or `sf-tl [3fa9c1]`)
  or is a `uds:` address whose process runs in a roster seat's pane, as a reply to a message does.
  Anything else, another team's session, a subagent or an address no seat holds, is written as given;
- the outcome is `sent` when the message reached the receiver's inbox, and `NOT-SENT` when
  `SendMessage` returned `success: false` or failed. `sent` is not `delivered`: a receiver in another
  permission mode can still hold a message for its user's approval, or refuse it, and that comes back
  later as a notice to the sender, which the log does not see;
- hook input that still cannot be read is logged as a line with the recipient `?`, the outcome
  `UNREADABLE` and the message `<hook input could not be read>`, so a message is never left out of
  the log without a trace.

The hook prints nothing and always exits 0, so a log it cannot write costs that line, never the message
or the tool result. Looking up the seat behind a `uds:` address (with `ps` and `tmux`) gives up after
2 seconds, killing what it started, and the address is then written as given. The message is written to
`messages.log` only, which holds every native message in full, private reports to the EM among them:
every seat but `em` has a `Read` deny on it (see [Safety](#safety)). A seat whose hooks are all off
(`disableAllHooks: true` in the user's settings, and no gate) logs nothing: `check` says which.
Messages a seat receives are logged by their sender, so traffic from outside the team is not logged.

## Safety

Each seat starts with a generated settings file, `.state/<team>/settings/<role>.json`, passed with
`--settings` and rewritten read-only on every `up`. It holds the team's `permissions` merged with the
role's (team first; a role can add or tighten a rule, never loosen one), plus what factory.sh adds:

- an `Edit` deny on the files that would change a seat's next start or its live rules: the generated
  settings, launchers and prompts, the message log and the gate's state, the team file and its
  prompts, the launcher (`factory.sh`, `lib/`, `roles/`, `plugin/`), any plugin given with `--plugin-dir`
  in `args`, and the claude `wrapper` (its whole `.app` bundle, if it is in one), the main checkout's `.mcp.json`, `.claude/settings.json`,
  `.claude/settings.local.json`, `.claude/CLAUDE.md`, and `.claude/hooks/`, `rules/`, `skills/`,
  `agents/` and `commands/` (not the root `CLAUDE.md`, which is project work), the
  seat's own `.claude/settings.json` and `settings.local.json`, and Claude Code's user settings, MCP
  config, instructions, user-level rules (`rules/`) and extensions under `~/.claude` and in `~/.claude.json` (and, when
  `CLAUDE_CONFIG_DIR` is set where `up` runs, under that folder too, with the `.claude.json` inside
  it; each seat's launch script pins the same value, so a seat uses a folder its rules protect, and
  the default folder stays protected for sessions started without the variable). `.claude/worktrees/` stays editable: Claude
  Code puts the worktrees it makes there, including those of a worktree seat's subagents, which land
  under the main checkout. A path that runs through a symlink is denied both as configured and as its
  real path, which stops `rm` and `mv` of a protected link; repointing a link with `ln -sf` is not a
  file command Claude Code checks, and is not stopped (checked on 2.1.316). The seat's own `.mcp.json`
  stays editable as project work; its servers normally need approval in a startup dialog, but with a
  user setting such as `enableAllProjectMcpServers` on they load unprompted at the next start;
- an `ask` on any push to the base branch (from `repo.base`), forced or not, since changes land through
  PRs. It is an early warning for a project whose base branch has no protection. The real control is a
  ruleset on the base branch that blocks force-push and deletion and requires a PR; where one exists,
  this ask is redundant;
- an `Edit` allow on the seat's own progress note (see [Progress notes](docs/workflow.md#progress-notes)), which is
  outside its working directory and would otherwise prompt in a mode other than bypass, and an `Edit`
  deny on every other seat's note: a note is put into its seat's context at each start, so a seat
  that could write another's would have a lasting channel into it;
- a `Read` deny on the message log, `.state/<team>/messages.log` (both spellings, when a symlink makes
  them differ), for every seat but the role with id `em`: the log holds every `SendMessage` in full. A
  team with no `em` role has the deny on every seat. This is an accident guard, not a boundary: every
  seat runs as the same OS user (#29), and a command that reads the file some other way is not stopped;
- rules on the security-triage record folder, `.state/<team>/triage/` (#138), where the
  `factory:security-triage` skill has `sec` write its records. A record can hold an unfixed
  medium-or-higher finding. The folder is outside every working directory, so without a rule each
  write and read would prompt in a mode other than bypass. The role with id `sec` gets an `Edit` and
  a `Read` allow on `triage/**`, the role with id `em` a `Read` allow (and an `Edit` deny), and every
  other seat an `Edit` and a `Read` deny, all in both spellings. `up` makes the folder (mode 700,
  set on an existing folder too) when the team has a `sec` role; nothing deletes a record. The role
  id is fixed: a team whose security seat has another id gets no record folder, every seat but `em`
  is denied it, and `check` warns about a role other than `sec` that lists the skill. Like the log's, these denies are an
  accident guard, not a boundary. As with any settings change, a `sec` seat that is already running
  when `up` writes these rules keeps its old settings until it restarts;
- denies on **other teams' state folders** (#197), when more than one team runs on the machine. For each
  other team's folder, every seat gets a `Read` deny on its `triage/**` and an `Edit` deny on all of
  it, plus a `Read` deny on its `messages.log` and `notes/**` unless the seat's role observes that team.
  All are written in both spellings. The other teams' folders come from two places:
  - **Found:** every real folder beside this team's own in the state root (`.state/`) that holds
    `settings/`, `launch/` and `prompts/`. A symlink there is never followed. `check` names the links
    it skips: list one under `other_teams` if it is another team's state.
  - **Listed:** `other_teams` in the team file, for a state folder elsewhere (a pinned team's, see
    [Pinned releases](docs/pinned-release.md)), each with its `observers`. These are the roles of this
    team the owner allows to read that team's log and notes, never its triage records:

    ```yaml
    other_teams:
      - { state: /path/to/other/state, observers: [qa2] }
    ```

  A listed folder may not be, hold or sit inside this team's own state folder, its repository, its
  worktree folder or a seat's working directory, whether or not it exists yet. The one exception is a
  team's state folder whose parent is a real folder named `.state`, which may sit inside them once that
  team has run `up` (a pinned team working on software-factory lists `<factory>/.state/<team>`). If
  it exists, it must be a team's state folder itself (holding `settings/`, `launch/` and `prompts/`),
  not its checkout or `.state/` above it. Outside them, one that doesn't exist yet, or is still empty,
  is accepted, and `check` says so. `check` lists the
  other teams found and listed, and each seat's denies. Settings are written at `up`, so a team that starts
  after a seat does is covered from that seat's next restart. Teams on one machine still share the
  machine user, so these denies are an accident guard, like the others: a command that reads or
  writes another way is not stopped. They also share the tmux server and the shared `claude`
  executable the copies come from.

  An observer may read the observed team's message log, which records that team's messages in full,
  so it can carry the private reports its seats send to `sec` and the EM: an unfixed security point
  among them, before it is rated ([#222](../../issues/222)). An observer treats everything in that log
  under rule 5 of its prompt ([`roles/common.md`](roles/common.md)): it never quotes the log anywhere,
  and sends `sec` and the EM only a pointer to what it saw: the team and the time of the log line, and
  its line number when several lines share that time.

`permission_mode` (in `sessions.claude`, or per role) picks the mode; the example uses `auto`.
`bypassPermissions` skips every prompt and is meant for an isolated machine only. Deny rules hold in
every mode, bypass included, and ask rules still prompt there, so a seat that hits one waits until
someone answers. `say` will not deliver to a seat at a permission prompt or any other dialog (see
[`say`](#say)): attach and answer it yourself. These rules add to the ones in `~/.claude/settings.json`
and the repo's `.claude/` settings, which still apply. `check` shows each seat's mode and rules, and is
where load-time errors (unknown modes, malformed rules, a permission flag in `args`) are reported.
It also warns, without stopping a start, about seats whose modes would hold messages between them
([Which messages are held](#which-messages-are-held)), and about any role whose rules have neither a
deny nor an ask on each of the merge patterns, unless that role is marked `may_merge: true` (a YAML
boolean, so an unquoted `yes` or `on` also counts as true). The patterns, the ones `teams/example.yaml`
denies or asks on ([#85](../../issues/85)):

- `Bash(gh pr merge *)`: `gh pr merge`, with or without arguments.
- `Bash(gh pr -* merge *)` and `Bash(gh pr -* merge)`: the same with a flag before the subcommand
  (`gh pr -R o/r merge 5`, `--repo o/r`, `--repo=o/r`). The space after `merge` keeps
  `gh pr -R o/r view 5 --json mergeable` out.
- `Bash(gh api *pulls/*/merge*)` and `Bash(gh api graphql*mergePullRequest*)`: the REST and GraphQL merge.
- `Bash(gh api graphql*enablePullRequestAutoMerge*)`: auto-merge.
- `Bash(gh api graphql*mergeBranch*)` and `Bash(gh api *repos/*/merges*)`: merging a branch without a PR.

A team file written before these were added gets the warning until it has them. Known false matches:
a `gh pr -R o/r <subcommand>` whose later text has ` merge ` in it, and `gh api` reads whose path or
query names these. Not covered: a GraphQL query read from a file or stdin (`-F query=@q.graphql`,
`--input`), `curl` or other HTTP clients against the API, `gh` aliases, extensions and scripts, a
`git push` of a merge commit to the base branch (the base-branch push ask covers that), and other
hosts' CLIs.

Claude Code's auto memory is off in every seat: the generated settings set `autoMemoryEnabled: false`
and `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, and the launch script exports the variable. Auto memory lives
in one folder per repository (`<config>/projects/<repo>/memory/`), shared by all its worktrees, and its
`MEMORY.md` loads into every session there, the owner's own in the main checkout included
([docs](https://code.claude.com/docs/en/memory#storage-location)). A seat's note there would reach every
other seat and the owner without review, outside the PR process. Set `auto_memory: true` under
`sessions.claude`, or on a role, to leave it to Claude Code's own settings (that seat's launch script
unsets the variable, so it is not inherited from a tmux server started inside a seat). `check` shows it per seat
in the MEMORY column.

Turning auto memory off stops a seat from writing memory by itself, but not from editing that folder
with its file tools. So every seat with auto memory off also gets an `Edit` deny (which covers the
Write tool too) on the repository's auto-memory folder, in every config folder and both spellings of
the main checkout's path ([#108](../../issues/108)). Claude Code names the folder after that path, with
every non-alphanumeric character turned into `-`; a name over 200 characters is matched by its first
200 and a `*`, because Claude Code appends a hash to it. As with the other denies, Bash redirects, `tee`
and `cp` into the folder are stopped too, and a script that opens the file itself is not (checked on
Claude Code 2.1.314). `check` names the deny in each seat's `added:` line. The deny covers only that
default folder: if you set `autoMemoryDirectory` in your settings, your sessions load memory from the
folder it names, and the deny keeps protecting a folder nobody reads, with no warning.

These rules are an accident guard, not a security boundary: every seat runs as the owner's OS user,
with the owner's GitHub credential, and can change what loads. [#29](../../issues/29) tracks making
them a boundary.

What the rules cannot do:

- A Bash rule matches the command text. The same program under another path (`/usr/bin/gh`), inside
  `sh -c`, in a script, or reached another way is not matched: for example `git -C <dir> push`, a bare
  `git push` while on the base branch, or `gh api` with a PATCH or DELETE on `git/refs/heads/<base>`.
- A `Read` deny covers Claude's file tools and the file commands it recognises in Bash (`cat`, `head`,
  `tail`, `sed`, `tee`, redirects). It does not cover `grep -r` over a folder, or a Python or Node
  script that opens the file itself.
- The protected-path `Edit` denies stop the file tools, redirects, and `cp`, `mv` and `rm` with a
  protected file as the target (checked on Claude Code 2.1.316). They match the command text Claude
  writes, so they do not stop the same command run through another shell or a script (`sh -c 'cp …'`,
  which qa checked gets through), or a program that writes the file itself, such as a Python or Node
  script.
- "Never force-push a branch you did not create" cannot be written as a pattern. Engineers keep
  force-pushing their own branches; only the EM is asked.
- Any process running as this user can type into a seat's pane, so an ask rule guards against
  accidents. It is not a gate that only the owner can pass.
- Seats act with the owner's GitHub rights, so they can change a ruleset or branch protection through
  the API. No rule here stops that (an ask that matched it would also stall seats reading the
  settings); [#29](../../issues/29) tracks the fix.
- Settings above these files apply as well: managed settings, and, depending on the account, installed
  mods, which can approve calls these rules would stop.
- Paths in Read and Edit rules: `//path` is absolute, `~/path` is under the home folder, `./path` or a
  bare name is relative to the seat's folder. A single leading `/` anchors at the folder that holds the
  generated file, so it is refused.
- Claude Code matches permission rules against each part of a compound command (`;`, `&&`, `|`), but
  against the whole command text when it can't parse the command (for example `"$(...)"` in an
  argument, such as a PR body from `$(cat <<EOF ...)`, or `${...}` next to quotes). In default mode, a
  subshell `( ... )` or a command it can't parse prompts even when no rule matches (the reason varies:
  "can't be checked before it runs", "shell operators that require approval"); in bypass mode it
  prompts only when a rule matches (measured on 2.1.316, [#103](../../issues/103); other modes not
  measured). So seats run `git push` as its own simple command: chained with an unparseable part, a
  `main` elsewhere in the command makes it match the base-branch ask. A prompt that names a rule
  (`Permission rule ... requires confirmation`) means the command's text matched an ask rule, even
  when the reason it shows is about parsing ("expansion obfuscation", "shell operators that require
  approval"): that reason only says why Claude Code could not narrow the prompt to the matching part.
  The shared prompt keeps the instructions (push alone, avoid a subshell, a named rule means a match)
  and leaves this mechanism here ([#117](../../issues/117)).
- Seats push with `git push origin <branch>:<branch>` on a branch cut with `--no-track`. A branch cut
  with `git switch -c <branch> origin/main` has the base as its upstream, so under
  `push.default=upstream` a bare `git push`, or even `git push origin <branch>`, would push to the base.

The [sandbox](https://code.claude.com/docs/en/sandboxing) is the OS-level control that would hold
whatever the command text, but the launcher does not turn it on: seats run without one unless settings
that apply to them enable it. The hard rules in the shared prompt (`roles/common.md`) still apply;
read them before changing them. A seat started in a folder Claude Code has not seen stops at a trust
dialog until a human answers it once; `up` reports which seats those are.

## The gate

Moved to [The gate](docs/gate.md).

## Progress notes

Moved to [How work is tracked: Progress notes](docs/workflow.md#progress-notes).

## Updating Claude Code

Claude Code's updater replaces its shared executable (the npm package's `bin/claude.exe`), even with
the same version, and every Claude Code session on the machine runs it, not only this team's seats.
macOS then can no longer identify a seat still running the old file, and the privacy grants it runs
under (a removable volume holding the worktrees, for example) stop working until the seat restarts
(#50). So:

- **Each seat runs the team's own copy of claude**, `.state/<team>/bin/claude-<version>/claude`. `up`
  makes it from the shared executable when it is missing: an APFS clone where the state folder is on
  the same file system (it takes no space while the shared file exists), else a plain copy. It is
  checked (size, `--version`) before use, and if it cannot be made, `up` stops instead of running the
  shared file. Nothing but `up` writes there, and seats cannot edit it.
- **The seats' own updater is off** (`DISABLE_AUTOUPDATER=1`, in the launch script and the generated
  settings), so the seats do not add reinstalls of their own.
- `check` names the shared executable, its version and the copy seats will run, and lists every copy
  with the running seats that use it. `status` shows each running seat's executable, or `REPLACED`
  when the file it runs has been swapped under it; `up` prints an ATTENTION line for such a seat.
  Restart it (`down --yes <role>`, then `up <role>`).

To update: `claude update` in your own shell (a manual update works with the variable set), then
`./factory.sh down --yes` and `./factory.sh up`. The next `up` copies the new version, and every seat
starts on it.

Old copies are never removed automatically. Once the shared file has moved on, each one holds about
310 MB. When `check` lists a copy with no running seat, remove that folder by its exact path, for
example `rm -r .state/<team>/bin/claude-2.1.314`.

## Tests

Moved to [Testing](docs/testing.md): [live tests](docs/testing.md#live-tests) and [the end-to-end test](docs/testing.md#the-end-to-end-test).
