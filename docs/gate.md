# The gate

The repository's pass/fail command, and how a seat is held to it when it stops with uncommitted work.

`repo.gate` is the repository's pass/fail command. A role with `gate_on_stop: true` gets a Stop hook in
its generated settings (`lib/stop_gate.sh`): whenever the seat ends a turn with uncommitted changes in
its working tree, the hook runs the gate there, and if it fails the seat is sent back to work with the
command, the last 60 lines of its output and the path of the full log (`.state/<team>/gate/<role>.log`).
Roles without the switch never run it. The example gives it to the engineers and qa.

## How it behaves

- Only uncommitted work is gated at a stop: a clean tree, including committed but unpushed work, ends
  the turn normally. Committed work is gated again when the reviewer runs the gate on the PR. A
  `git status` that fails (a corrupt index, say) counts as uncommitted work: the gate runs, and a
  send-back says status failed. The hook's git calls do not run a repository's fsmonitor program;
  clean filters stay on, because status needs them for a correct answer ([#104](../../../issues/104)).
- Only the seat's configured working tree is checked. Work left in another tree, such as a worktree
  Claude Code made for a subagent or for `EnterWorktree` under `<repo>/.claude/worktrees/`, is not
  gated.
- The gate catches mistakes, not a seat that edits the gate. It runs the scripts in the seat's own tree
  (a Makefile, test scripts), at the stop and outside Claude Code's permission rules: no prompt, no
  deny or ask rule, no auto-mode classifier. A seat that changes those files decides whether its gate
  passes and what runs at its next stop, so for a seat that is not in bypass mode, permission to edit
  its tree becomes commands that run unprompted at the stop. The reviewer's own run of the gate on the
  PR stays the real check.
- A seat also stops on purpose: to wait for an answer or a review, or with a test red before the fix.
  After `repo.gate_max_blocks` (default 3) failed gates in a row in one turn, the next stop in that turn
  goes through without running the gate again, with a note that the gate is still failing. Every
  send-back tells the seat that, if it is stopping on purpose, it should say so in its report, and
  gives the limit (this moved here from the shared prompt, [#117](../../../issues/117); the let-through's
  note is shown to the user, not to the seat). Each new turn starts from zero, so a seat that lives
  for days is never gated off for good. The count is in the state folder, which seats cannot edit through Claude
  Code's tools; a passing gate or a clean tree resets it. A script can still write it, or run the hook
  with made-up input, like every other "a script can do it" limit under [Safety](../README.md#safety). Run by hand
  with no hook input, `lib/stop_gate.sh` runs the gate and reports but leaves the count alone. Claude
  Code also ends such a loop itself after 8 continuations with no tool call in between (raise it with
  `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`).
- The hook never writes or reads its state through a link ([#194](../../../issues/194)). A symlink, a
  hard link, or anything other than a folder or a regular file, at `.state/<team>/gate/` or at the
  role's log or count in it, is refused: no gate runs and nothing is written. The seat is sent back,
  told to report it; in a turn the hook has already sent back, the stop goes through with a note naming
  it. Only a seat could put one there; remove it by its exact path.
- The gate runs with a time limit (`repo.gate_timeout`, default 600 s) in a process group of its own,
  which is killed whole when the time is up. A program that detaches from that group (a daemon, a tmux
  server) is not killed.
- The hook inherits the seat's environment, which runs inside tmux: a gate that must not touch the
  team's tmux server unsets `TMUX` itself, as this repository's does.
- The gate runs at every such stop, so a slow gate (this repository's e2e takes over a minute) makes
  those stops slow.
- A gated seat's settings set `disableAllHooks: false`, so a `.claude/settings.json` in the project
  cannot switch the gate off. That also turns the user's own hooks back on for that seat if
  `~/.claude/settings.json` had switched them all off.
- The stop gate does not take the [run-exclusive](#one-heavy-run-at-a-time) lock yet
  ([#236](../../../issues/236)). A wait for it would count against `repo.gate_timeout` and come back as a
  failing gate, sending the seat back for a failure that is not real.

## One heavy run at a time

Every seat running a full gate or test run at once loads a machine until timing tests fail for no
other reason ([#214](../../../issues/214)). `factory.sh run-exclusive -- <command> [args...]` runs one such
command at a time across every seat of every team on the host, and the owner's shell:

```
./factory.sh run-exclusive -- make check
./factory.sh run-exclusive -- env -u TMUX TEST_VOLUME=/Volumes/YourDrive test/e2e.sh
```

- **It waits, and never fails for a busy lock.** It prints who holds the lock (role, team file, pid,
  folder), since when and the command, then a reminder every 5 minutes, and "got the lock" when its
  turn comes. Ctrl-C while waiting exits 130 without running anything.
- **The command** is an argument list, not a shell string (write a pipeline as `bash -c '...'`). It
  runs in a process group of its own, so it cannot read the terminal. The exit status is the
  command's, or 128 plus the signal that ended it. It needs no team file, so it works from any checkout.
- **The lock** is one file per user, `~/Library/Application Support/software-factory/run-exclusive.lock`,
  outside every team's state and checkout. Teams on one machine share the user, so they share the lock.
  `FACTORY_RUN_LOCK` names another file (the e2e uses its own). The folder is owner-only, and a lock
  file that is a symlink or a hard link is refused. Never remove the lock file while a run holds it: a
  run that starts after that does not wait for the one holding it, and the holder can only say so when
  it ends.
- **The lock ends with the command.** It is released when the command ends or when its run is killed:
  TERM, INT or HUP is passed on to the command's group, and a run killed with SIGKILL has its lock
  dropped by the system. A command whose run was killed with SIGKILL is not stopped and can overlap
  the next run. The lock is never handed to the command, so a daemon it leaves running (a tmux server)
  does not hold it.
- **Nested runs** (a gate script that calls `run-exclusive` again) run at once instead of waiting for
  themselves, but only while the run that holds the lock is alive. A program left running from an
  earlier run keeps its variable, and that alone does not skip the lock.
