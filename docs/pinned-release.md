# Running a team from a pinned release

A team normally runs from the checkout of software-factory it was started from. Its seats call that
checkout's `factory.sh` for `say`, run its hooks, load its plugin, and keep their state under its
`.state/<team>/`. So every change that lands in that checkout reaches the running seats at once,
mid-task. To keep a team on a known version while this repository keeps changing, run it from a
checkout of its own, fixed at a release, and upgrade it only when you choose to ([#189](../../../issues/189)).

The placeholders below stand for your own paths and names:

| Placeholder | What it is |
|---|---|
| `<factory>` | Your main checkout of software-factory. |
| `<release>` | A tag or a commit of software-factory, for example `v0.1.0`, the first release tag. Release tags are annotated, and a tag's message holds that release's notes, including any change to the state layout. Creating and pushing a tag is the owner's step. A commit works the same way, and `check` names a lightweight tag as well as an annotated one. |
| `<releases>` | A folder outside `<factory>` that holds one checkout per release, for example `<releases>/factory-<release>`. |
| `<state>` | The team's state folder, outside every checkout, on the same volume as `<factory>`. |
| `<team>` | The team's name (`team:` in the team file). |
| `<name>` | The project's folder under `projects/`, the one the team file's prompt paths name. |

## What comes from where

Every path a seat uses comes from the checkout whose `factory.sh` ran `up` for it, and stays fixed
until that seat restarts:

| What | Where it comes from |
|---|---|
| `say` | The seat's `TEAM_SCRIPT` (set in its tmux session) and the `factory.sh` path in its prompt. Both name that checkout's `factory.sh`. |
| Hooks | The seat's settings name that checkout's `lib/session_start.sh`, `lib/log_message.sh` and `lib/stop_gate.sh`. |
| Plugin | The seat's launch script passes `--plugin-dir` with that checkout's `plugin/`. |
| Prompts | Rendered at `up` from that checkout's `roles/` and the team file's prompts. |
| State | That checkout's `.state/<team>`. Here it is a symlink to `<state>`, so every release shares one state folder: progress notes, the message log, triage records, the gate's counters and the team's copies of claude. |

`./factory.sh check` prints the checkout it runs from and its `git describe`, for example
`install   : <releases>/factory-<release> at <release>`. A checkout with uncommitted changes ends
in `-dirty`.

Do not use `TEAM_STATE_DIR` for a pinned team. `up` honours it, but the seats do not get it, so a seat's
`say` would look for the state under its checkout's `.state/` instead.

## Set up a release checkout

1. Make the checkout from your main checkout:

   ```
   git -C <factory> fetch --tags
   git -C <factory> worktree add --detach <releases>/factory-<release> <release>
   ```

2. Copy the team file and the project's prompts into it. Both are git-ignored, so the checkout starts
   without them:

   ```
   cp <factory>/teams/<team>.yaml <releases>/factory-<release>/teams/
   mkdir -p <releases>/factory-<release>/projects
   cp -pR <factory>/projects/<name> <releases>/factory-<release>/projects/
   ```

   Make `projects/` first: a new checkout has no `projects/` folder, so without it `cp` makes
   `projects/` itself the copy of `<name>`. The prompts then land at `projects/project.md`, not
   `projects/<name>/project.md`, and `check` fails with `prompt file not found`
   ([#218](../../../issues/218)). `teams/` needs no `mkdir`, because it is tracked (it holds
   `example.yaml`).

   Keep the prompt paths in the team file relative to it (`../roles/common.md`, `../projects/<name>/...`),
   so each checkout uses its own copy. An absolute path keeps pointing at whichever checkout it names.
   The team file must sit in that checkout's `teams/`, or `up` treats the team as a throwaway one
   ([Throwaway teams](commands.md#throwaway-teams)).

3. Link the shared state folder into it:

   ```
   mkdir -p <releases>/factory-<release>/.state
   ln -s <state> <releases>/factory-<release>/.state/<team>
   ```

From then on, run every command for this team with that checkout's `factory.sh` and team file:
`<releases>/factory-<release>/factory.sh -c <releases>/factory-<release>/teams/<team>.yaml <command>`.

A seat protects only the checkout it runs from. A release checkout is a worktree of your main checkout,
so another team on this machine, one working on software-factory above all, could edit it, or remove
or prune it with git, and change the code the pinned team runs at its next start. Add a deny for the
releases folder to every other team file's `permissions`. For a releases folder at `/path/to/releases`,
that is `deny: ["Edit(//path/to/releases/**)"]` (an absolute path takes `//` in a rule). Or keep it
where those teams never work.

The releases-folder deny goes in the other teams' files only, never in the pinned team's own. Each
seat's prompt names its progress note through its checkout's state link,
`<releases>/factory-<release>/.state/<team>/notes/<role>.md`, which is inside the releases folder. In
the pinned team's file, the deny covers that path, and a deny wins over the allow the seat's settings
give its note, so every seat is refused when it writes its note by the path its prompt gives
([#219](../../../issues/219)). For the same reason, give each pinned team a releases folder of its
own: two pinned teams sharing one would each deny it in the other's file, and so block each other's
notes.

The shared `<state>` folder, which holds the pinned team's notes, log and records, needs the same care
in both directions, and the factory finds neither direction itself. It finds another team's state only
as a real folder beside its own: `<state>` is not beside the other teams' folders, and the pinned
team's checkout holds only a link to it, which is never followed. So list them under `other_teams` (see [Safety](../README.md#safety)), in **both** team files:

- in every other team's file, the pinned team's `<state>`:
  `other_teams: [{ state: /path/to/state }]`;
- in the pinned team's file, each other team's state folder, for example
  `other_teams: [{ state: <factory>/.state/<other team> }]`.

A listed folder that doesn't exist yet, or is still empty because that team hasn't run `up`, is
accepted, and `check` says so. If the pinned team works on software-factory itself, so that its
`repo.path` is `<factory>`, it may still list `<factory>/.state/<other team>` although that is inside
its repository: a team's state folder whose parent is a real folder named `.state` is the one thing
inside its own work that a team may list. That holds only once the other team has run `up`: until then
the folder is missing or empty, and such a folder inside the repository is refused.

Each seat then gets a Read deny on the listed team's triage records, message log and notes, and an Edit
deny on the whole folder, from its next start. Add `observers: [<role>]` to an entry for a role the
owner allows to read that team's log and notes. Run `check` with each team file to see the denies.
Like the other rules, these are accident guards: a shell command that reads or writes there another
way is not stopped.

## Move an existing team to a release (once)

The team's state is moved, not copied, so nothing is left behind:

1. Ask every seat to write its handoff (the `factory:handoff` skill), and wait until each has.
2. Note what to check afterwards: the number of files in `<factory>/.state/<team>/notes/`, the last line
   of `<factory>/.state/<team>/messages.log`, and the number of records in `triage/`, if there is one.
3. Stop the team from the main checkout: `<factory>/factory.sh -c <factory>/teams/<team>.yaml down --yes`.
4. Move the state folder: `mv <factory>/.state/<team> <state>`. `<state>` must not exist yet: if it
   does, `mv` puts the folder inside it, at `<state>/<team>`, and the link would then point one level
   too high, so `up` would start with no notes and no log. Check right after the move that
   `<state>/notes/` and `<state>/messages.log` exist. On one volume, the move is a rename, and nothing is
   copied or lost. To another volume, `mv` copies and then deletes: do it only with every seat down, and
   check the counts before you rely on it.
5. Set up the release checkout as above, steps 1 to 3.
6. Move the team file out of the main checkout's `teams/`, so the main checkout cannot start this team
   by mistake.
7. Check that nothing was lost: the same number of notes in `<state>/notes/`, the same last log line, and
   the same triage records.
8. Run `check` from the release checkout, then `up`. `up` writes new settings, prompts and launch
   scripts, and a new copy of claude if needed. The notes, the log and the records carry over, and each
   seat's prompt names its note through the link.

## Upgrade to a newer release (rolling)

1. Set up a checkout for the new release, with `<new>` for `<release>`: steps 1 to 3 of
   [Set up a release checkout](#set-up-a-release-checkout), the `mkdir` of `projects/` included, linked
   to the same `<state>`.
2. For each seat in turn, once it has written its handoff:

   ```
   <releases>/factory-<new>/factory.sh -c <releases>/factory-<new>/teams/<team>.yaml down --yes <role>
   <releases>/factory-<new>/factory.sh -c <releases>/factory-<new>/teams/<team>.yaml up <role>
   ```

3. When no seat runs the old release, remove its checkout (below).

A seat not yet restarted keeps running the code it started with: its `say`, hooks and plugin all name
the old checkout, which the upgrade does not change. So keep the old checkout in place until its last
seat has restarted. To see which release a seat runs:
`tmux show-environment -t '=<prefix>-<role>' TEAM_SCRIPT`.

During the overlap, old and new seats share the state folder: the message log, the notes, the locks
`say` takes and the claude copies. They can message each other, and both write the same log. That is
safe only while the two releases agree on two things:

- **The state layout.** If the new release's notes (its tag's message: `git -C <factory> tag -n99 -l <new>`)
  say it changed what is kept in the state folder, or how, upgrade with a full restart instead.
- **The team file.** Each checkout has its own copy of the team file, and an old seat's `say` reads the
  old copy. A changed team file (a role added or removed, a changed prefix or session name, a changed
  roster) needs a full restart, not a rolling one.

A full restart: handoffs, `down --yes` from the old checkout, then `up` from the new one.

## Remove an old release checkout

Once no seat runs it, remove the state link and the team file by their exact paths, then the checkout:

```
rm <releases>/factory-<old>/.state/<team>
rmdir <releases>/factory-<old>/.state
rm <releases>/factory-<old>/teams/<team>.yaml
git -C <factory> worktree remove <releases>/factory-<old>
```

Removing the link deletes the link, never the shared state it points to. (In the live check on #189,
`git worktree remove`, with or without `--force`, also deleted only the link when it was left in
place. Remove it by its path anyway, so nothing relies on that.) Git-ignored files do not stop
`git worktree remove`, which deletes them with the checkout, the copied project prompts included.

Updating Claude Code is unchanged: see [Updating Claude Code](../README.md#updating-claude-code). The
copies of claude live in the shared state folder, so every release uses them.
