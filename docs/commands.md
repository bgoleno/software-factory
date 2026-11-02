# Commands

What software-factory needs, every `factory.sh` command and its options, which team file a command
uses, and the iTerm view. For what `up` does step by step, see [How it works](how-it-works.md).

## Requirements

macOS, `tmux`, `claude` (Claude Code), `git` 2.36 or later (for `git worktree list -z`), `gh`, and the
system `ruby` (it parses the YAML; it ships with macOS). Optional: a wrapper program that runs claude (see
`sessions.claude.wrapper`). A C compiler is needed only for `test/e2e.sh`.

## The commands

```
cp teams/example.yaml teams/team.yaml     then edit it: repo, project, storage, roles
./factory.sh check                        validate the team file, show where everything lives
./factory.sh up [role...]                 start the team (all roles, in file order)
./factory.sh status                       which seats are up, and where each works
./factory.sh view                         open an iTerm tab with every running seat in a pane
./factory.sh titles                       set each running seat's terminal title (role | title | session)
./factory.sh say <role|all> "..."         type a message into a seat (seats use SendMessage)
./factory.sh attach <role>                attach your terminal (detach: ctrl-b d)
./factory.sh migrate [role...]            remove clean worktrees that are not on the storage volume
                                          (never one a running process works in)
./factory.sh down --yes [role...]         kill seats (worktrees are kept)
./factory.sh run-exclusive -- <command>   run a heavy command (a gate, an e2e run) one at a time on this
                                          host, waiting for the run before it (needs no team file)
./factory.sh -c path/to/other.yaml up     use a different team file
```

Options:

- `up --no-view` starts the seats without opening the iTerm view.
- `view --print` prints the AppleScript that would build the view, for every role in the team file,
  running or not, and opens nothing.
- `down` without `--yes` lists the seats it would kill and kills nothing.
- `attach` with no role attaches to the first role in the team file. Run from inside tmux, it switches
  your tmux client to the seat instead of attaching.
- `--default-socket` (on `up`, `down`, `say`, `attach`, `view` and `titles`) lets a team file outside
  `teams/` run on the default tmux server: see [Throwaway teams](#throwaway-teams). On `say` and
  `attach` it must be the first argument.
- `-c` (or `--config`) comes before the command.
- `run-exclusive` takes the command after `--`, as an argument list. See
  [One heavy run at a time](gate.md#one-heavy-run-at-a-time) for the lock and what it covers.

## Which team file

The team file is `-c`, else `$TEAM_CONFIG`, else `teams/team.yaml`. `teams/example.yaml` documents every
key. Team files other than the example, and anything under `projects/`, are git-ignored so each
project's specifics stay out of this repository. Keep a project's own prompts under `projects/<name>/`
and point the team file at them.

## Throwaway teams

`up` takes a team file outside `teams/` for a throwaway one (a test) and will not start its seats on your
default tmux server, where a real team runs: run it on a private server (see
[Live tests](testing.md#live-tests)), or pass `up --default-socket` if that team is meant to run there. `down`
(with or without `--yes`), `say`, `attach`, `view` and `titles` apply the same rule before any tmux call,
because a copy of a real team file shares its session prefix and would reach the real seats: kill them,
type into them, show them or relabel them ([#105](../../../issues/105), [#124](../../../issues/124)).
`status` only reads, and `migrate` keeps any worktree a running process works in, on whatever server
([#121](../../../issues/121)). It reads each worktree's path whole, so a path with a newline in it is
acted on under its full path and shown escaped, never split in two ([#134](../../../issues/134)).
`up --default-socket` passes the option on to the view it opens. So a throwaway team file never goes in
`teams/`, neither this checkout's nor a worktree's copy of it: there every command takes it for a real
one. Put it in a temporary folder and run it on a private server.

## The iTerm view

`up` opens a new iTerm tab showing every running seat, unless `--no-view` is given or `display.iterm`
is `false`; `view` opens it any time. The primary seat (`display.primary`, default the first role) is
the left half at full height, since it is the one you talk to. The others fill rows on the right, two
per row, and an odd last seat gets a full-width row. The window is sized to the usable area of the
screen it is on (`display.window: full`). Each pane is a `tmux attach` to the seat's session, so
closing the tab detaches and never stops a seat. Each pane's header reads `<role> | <title> | <session>`:
the launcher sets tmux's `set-titles-string` on every seat (at start, and again by `view` or `titles`).
The first run asks macOS for permission to control iTerm.
