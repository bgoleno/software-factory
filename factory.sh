#!/usr/bin/env bash
#
# Start, message and stop a team of Claude Code sessions, each in its own persistent tmux
# session, each told its role, able to message each other through `say`. The team (roles,
# prompts, session names, claude flags, and where worktrees live) is defined in a YAML file:
# see teams/example.yaml, which documents every key.
#
#   factory.sh [-c team.yaml] <command>
#
#   check                      validate the team file and show where everything will live
#   up [--no-view] [--default-socket] [role...]
#                              start the team (default: every role, in file order); skips seats that are up,
#                              then opens the iTerm tab (see `view`) unless --no-view or display.iterm is false
#   titles                     set each running seat's terminal title to "<role> | <title> | <session>" (up and
#                              view do this too); it is what iTerm shows in each pane's header
#   view [--print]             open a new iTerm tab with every running seat in a pane: the primary seat
#                              (display.primary, default the first role) on the left at full height, the others
#                              in rows on the right; the window is sized to its screen (display.window)
#   status                     which seats are up, and where each one works
#   say <role|all> <message>   type a message into a seat (this is how seats talk to each other)
#   attach <role>              attach your terminal to a seat (detach: ctrl-b d)
#   migrate [role...]          remove clean worktrees that are not under the configured storage
#                              volume, so `up` recreates them there (stop the seat first)
#   down --yes [role...]       kill seats (worktrees are kept)
#   run-exclusive -- <cmd...>  run a heavy command (a full gate, an e2e run) when no other run-exclusive
#                              on this host runs one: waits, saying who holds the lock; needs no team file
#
# up, view, titles, say, attach and down refuse a team file outside teams/ on the default tmux
# server, where the real team runs: it looks like a throwaway copy. Run it on a private server
# (test/live-env.sh), or pass --default-socket (say and attach: as the first argument) for a team
# meant to run there.
#
# The team file is -c, else $TEAM_CONFIG, else teams/team.yaml next to this script.
#
# Each seat starts with a generated settings file (--settings): the team's and its role's
# permission rules, plus Edit denies on the files that would change its next start. Deny and ask
# rules hold in every permission mode, bypassPermissions included; they match command text, so
# they guard against accidents, not against a determined process. A seat's role is delivered as an
# appended system prompt (it survives compaction) plus a short first message.
#
# A tmux session is a shell that runs claude, so quitting claude leaves the shell and the
# session alive; `up` after that skips the seat. Run `down` first to start it fresh.
#
# Environment: TEAM_CONFIG (team file), TEAM_STATE_DIR (generated prompts, launchers, settings
# and the message log; default .state/<team>/ next to this script).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="$HERE/factory.sh"
RB="$HERE/lib/team_config.rb"

CONFIG=${TEAM_CONFIG:-$HERE/teams/team.yaml}
while [ $# -gt 0 ]; do
  case $1 in
    -c | --config)
      [ $# -ge 2 ] || { echo "error: $1 needs a file" >&2; exit 64; }
      CONFIG=$2
      shift 2
      ;;
    *) break ;;
  esac
done

# run-exclusive (#214) is for any seat of any team on this host, and the owner's shell, from any
# checkout: it runs before the team file is read, so a missing or broken one does not stop a gate run.
if [ "${1:-}" = run-exclusive ]; then
  shift
  exec ruby "$HERE/lib/run_exclusive.rb" "$@"
fi

die() { echo "error: $*" >&2; exit 1; }
command -v ruby >/dev/null || die "ruby not found (it parses the team file; it ships with macOS)"
[ -f "$CONFIG" ] || die "team file not found: $CONFIG (copy teams/example.yaml to teams/team.yaml and edit it, or pass -c <file>)"
CONFIG=$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")
export TEAM_CONFIG=$CONFIG

cfg() { ruby "$RB" "$CONFIG" "$@"; }

# Every command validates the file first: a typo or a missing prompt stops here, not after
# half a team has started.
cfg validate

TEAM=$(cfg get team)
REPO=$(cfg get repo.path)
GITHUB=$(cfg get repo.github)
PROJECT_NAME=$(cfg get project.name)
PROJECT_URL=$(cfg get project.url)
BASE=$(cfg get repo.base)
BOOTSTRAP=$(cfg get repo.bootstrap)
COPY_PATHS=$(cfg get repo.copy)
VOLUME=$(cfg get storage.volume)
WT_ROOT=$(cfg get storage.worktree_root)
PREFIX=$(cfg get sessions.prefix)
WRAPPER=$(cfg get sessions.wrapper)
VIEW_ITERM=$(cfg get display.iterm)
VIEW_PRIMARY=$(cfg get display.primary)
VIEW_WINDOW=$(cfg get display.window)
ROLES=$(cfg ids | tr '\n' ' ')
STATE=$(cfg get state.dir)
LOG="$STATE/messages.log"

title() { cfg role "$1" title; }
session() { cfg role "$1" session; }
workdir() { cfg workdir "$1"; }
wtype() { cfg role "$1" workdir_type; }

check_role() {
  case " $ROLES" in
    *" $1 "*) ;;
    *) die "unknown role '$1' (roles: $ROLES)" ;;
  esac
}
alive() { tmux has-session -t "=$(session "$1")" 2>/dev/null; }

# The socket a plain `tmux` command run from here reaches, worked out the way tmux 3.7 picks it: the
# one named in $TMUX when that is set, else tmux-<uid>/default under TMUX_TMPDIR. tmux falls back to
# /tmp, silently, when TMUX_TMPDIR is empty or names a folder that does not exist (seen 2026-10-30),
# so those count as /tmp. A value with a colon is taken as /tmp too, since it cannot be told apart.
# tmux connects through links, so the whole path is resolved (real_path): a private-looking
# TMUX_TMPDIR whose tmux-<uid> folder or socket links to the default one is the default one.
tmux_socket() {
  local d s
  if [ -n "${TMUX:-}" ]; then
    s=${TMUX%%,*}
  else
    d=${TMUX_TMPDIR:-}
    case $d in "" | *:*) d=/tmp ;; esac
    [ -d "$d" ] || d=/tmp
    s=$d/tmux-$(id -u)/default
  fi
  real_path "$s"
}
default_tmux_socket() { real_path "/tmp/tmux-$(id -u)/default"; }

# Path $1 with every link in it resolved, as far as it exists (the socket or its folder may not exist
# yet); the rest is appended as written. A relative path is taken from the current folder, as tmux does.
real_path() {
  ruby -e 'p = ARGV[0]; rest = []
    until File.exist?(p) || p == File.dirname(p)
      rest.unshift(File.basename(p)); p = File.dirname(p)
    end
    puts File.join(File.realpath(p), *rest)' -- "$1"
}

# A team file outside teams/ next to this script is taken for a throwaway one (a test), which must
# not reach seats on the default tmux server, where the real team runs (#66). A copy of the real
# team file shares its session prefix, so it would reach the real seats: up would start beside
# them, down kill them, say type into them, attach and view show them, titles relabel them. So
# up, down, say, attach, view and titles call this first, before any tmux call (#105, #124).
# Two commands that reach seats do not: status only reads, and migrate removes worktrees, not
# sessions, and keeps any worktree a running process works in, whatever server it reaches (#121).
# --default-socket overrides it for a team that is meant to run there.
# Usage: refuse_default_tmux <command> <what it would do>.
refuse_default_tmux() {
  local cmd=$1 what=$2 teams dir
  teams=$(CDPATH= cd -- "$HERE/teams" 2>/dev/null && pwd -P) || teams=$HERE/teams
  dir=$(CDPATH= cd -- "$(dirname "$CONFIG")" && pwd -P)
  case $dir/ in "$teams"/*) return 0 ;; esac
  [ "$(tmux_socket)" = "$(default_tmux_socket)" ] || return 0
  die "refusing to $what for $CONFIG on the default tmux server ($(default_tmux_socket)), where your real team runs: the team file is outside $HERE/teams/, so it looks like a throwaway team. Run it on a private server: d=\$($HERE/test/live-env.sh new); $HERE/test/live-env.sh run \"\$d\" $SELF -c $CONFIG $cmd (or unset TMUX and point TMUX_TMPDIR at a folder that exists). If this team is meant to run on the default server, pass $cmd --default-socket."
}

# The worktree volume is proven from the mount table, at the moment a worktree is created, and
# the target folder is proven to be on it. `mkdir -p` under an unmounted /Volumes path would
# quietly create the folder on the internal disk, so nothing is created before this passes.
require_volume() {
  mount | grep -qF " on $VOLUME (" || die "storage volume $VOLUME is not mounted; refusing to put worktrees on another disk"
  mkdir -p "$WT_ROOT" || die "cannot create $WT_ROOT"
  local on t
  on=$(df -P "$WT_ROOT" | awk 'NR==2 { $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print }')
  [ "$on" = "$VOLUME" ] || die "$WT_ROOT is on '$on', not on the storage volume $VOLUME"
  t=$(mktemp "$WT_ROOT/.write-test.XXXXXX") || die "cannot write to $WT_ROOT"
  rm -f "$t"
}

# The paths of the repo's registered worktrees, each ended by a NUL. Read with -z, which ends every
# field with a NUL, never line by line (#134): a path may hold a newline, and read as lines it would
# be two paths, the first a truncated one that a command could then act on. Read the output with
# `read -r -d ''`, and show a path with log_field, which escapes a newline.
worktree_paths() {
  local f
  git -C "$REPO" worktree list --porcelain -z | while IFS= read -r -d '' f; do
    case $f in "worktree "*) printf '%s\0' "${f#worktree }" ;; esac
  done
}

# Callers read worktree_paths through a process substitution, and bash drops its exit status. So a
# git that cannot list would look like a repo with no other worktrees: migrate would report
# "removed 0" and up would skip #121's legacy refusal, both without a word. That happens with a git
# older than 2.36, which added -z, or a repository git cannot read. Each caller runs this first, in
# its own shell, so the failure stops the command instead. Both failures persist, so one check
# before the read is enough; git failing only between the two calls is not handled.
require_worktree_list() {
  git -C "$REPO" worktree list --porcelain -z >/dev/null ||
    die "cannot list the worktrees of $REPO with 'git worktree list --porcelain -z' (needs git 2.36 or later)"
}

# Registered worktrees of the repo with this folder name that are not at the expected path, each
# ended by a NUL (worktree_paths). The name is taken with ${p##*/}, not basename: $(basename ...)
# would drop a newline that ends the path.
other_worktrees_named() {
  local name=$1 expected=$2 p
  while IFS= read -r -d '' p; do
    if [ "${p##*/}" = "$name" ] && [ "$p" != "$expected" ]; then printf '%s\0' "$p"; fi
  done < <(worktree_paths)
  return 0
}

# Create the worktree detached at the base ref, but never reuse or alter one that exists: it
# may hold a seat's unfinished work.
ensure_worktree() {
  local id=$1 dir url legacy p
  dir=$(workdir "$id")
  if [ -d "$dir" ]; then
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "$dir exists but is not a git worktree"
    if setup_wanted && ! setup_done "$id" "$dir"; then
      echo "  $id: $dir is not marked set up (a start was stopped, or repo.copy or repo.bootstrap came later); setting it up now"
      bootstrap_worktree "$id" "$dir" existing
    fi
    return 0
  fi
  require_worktree_list
  legacy=""
  while IFS= read -r -d '' p; do legacy="$legacy${legacy:+, }$(log_field "$p")"; done < <(other_worktrees_named "$(cfg role "$id" worktree_name)" "$dir")
  if [ -n "$legacy" ]; then
    die "'$id' already has a worktree elsewhere ($legacy). Stop the seat and run: $SELF migrate $id"
  fi
  require_volume
  url=$(git -C "$REPO" remote get-url origin)
  case $url in
    *"$GITHUB"*) ;;
    *) die "origin of $REPO is '$url', expected it to contain '$GITHUB'" ;;
  esac
  git -C "$REPO" fetch --quiet origin "${BASE#origin/}" || echo "warning: fetch failed; using the local $BASE" >&2
  git -C "$REPO" worktree add --detach "$dir" "$BASE" >/dev/null
  echo "  created worktree $dir"
  if setup_wanted; then bootstrap_worktree "$id" "$dir" new; fi
}

# A worktree up has made has none of the main checkout's git-ignored files and no installed
# dependencies (#10). Copy repo.copy's paths from the main checkout (never over a file the worktree
# already has), then run repo.bootstrap there with no terminal input, its output shown as it runs.
# Only then is the setup marked done, in <state>/setup/<role> (the worktree's real path): up checks
# that mark for every worktree it finds, and redoes the setup when it is missing, because a start
# can be stopped anywhere (a signal, a kill, a crash) and the seat must never start in a worktree
# set up halfway. A failure, or INT, TERM or HUP meanwhile, stops up; a worktree this up has just
# made is then removed by its exact path, and an existing one (it may hold work) is left as it is.
BOOT_DIR="" BOOT_PID="" BOOT_NEW=""
setup_wanted() { [ -n "$BOOTSTRAP" ] || [ -n "$COPY_PATHS" ]; }
setup_mark() { echo "$STATE/setup/$1"; }
setup_done() { [ "$(cat "$(setup_mark "$1")" 2>/dev/null)" = "$(cd "$2" && pwd -P)" ]; }

bootstrap_worktree() {
  local id=$1 dir=$2 p rc real_repo real_dir
  BOOT_DIR=$dir BOOT_NEW=$3
  trap 'boot_interrupted' INT TERM HUP
  rm -f "$(setup_mark "$id")"
  real_repo=$(cd "$REPO" && pwd -P); real_dir=$(cd "$dir" && pwd -P)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Neither side may lead the copy outside (sec and qa2, PR #106): a symlinked folder in the main
    # checkout would copy from wherever it points, a symlink copied as a link would let writes go
    # through to its target, and a tracked symlinked folder in the fresh worktree would have mkdir -p
    # and cp write through it. The target's deepest existing folder is checked before mkdir -p,
    # which itself writes through such a link.
    if [ ! -e "$REPO/$p" ] && [ ! -L "$REPO/$p" ]; then
      echo "  warning: repo.copy: $REPO/$p does not exist; not copied" >&2
    elif ! inside "$(cd "$(dirname "$REPO/$p")" && pwd -P)" "$real_repo"; then
      setup_failed "repo.copy: $p is outside the main checkout (a symlinked folder leads out of it)"
    elif [ -n "$(find "$REPO/$p" -type l -print -quit 2>/dev/null)" ]; then
      setup_failed "repo.copy: $p is or contains a symlink; repo.copy copies only real files and folders"
    elif [ -e "$dir/$p" ] || [ -L "$dir/$p" ]; then
      echo "  repo.copy: $p is already in the worktree; left as it is"
    elif ! inside "$(deepest_real_dir "$(dirname "$dir/$p")")" "$real_dir"; then
      setup_failed "repo.copy: $p would be written outside the worktree (a symlinked folder leads out of it)"
    elif mkdir -p "$(dirname "$dir/$p")" && cp -pR "$REPO/$p" "$dir/$p"; then
      echo "  copied $p"
    else
      setup_failed "repo.copy could not copy $REPO/$p"
    fi
  done <<<"$COPY_PATHS"
  if [ -n "$BOOTSTRAP" ]; then
    echo "  bootstrap: $BOOTSTRAP (output below as it runs; a long install takes a while)"
    # In the background with job control on, so the bootstrap and everything it starts are one
    # process group that the trap can stop (a trap waits for a foreground child, which a hung
    # bootstrap never ends), and so a Ctrl-C reaches up, not the install. sed -l passes each line
    # on as it comes. It runs without the messaging and tmux variables of a seat that runs up: a
    # seat's messaging token must not reach an install script (sec, PR #106).
    # The messaging ones are every name that starts with CLAUDE_CODE_MESSAGING_ (#164, agreed with tl),
    # so one a later Claude Code adds is dropped too. They are dropped with env -u, not unset: bash
    # lists an inherited name that is not a shell identifier in ${!prefix@} and passes it on to its
    # children, but cannot unset it. Not an env -i allowlist: docs/team-file.md promises the bootstrap
    # every other variable, and installs rely on the user's (proxies, SSH_AUTH_SOCK, tool paths).
    local v; local -a drop=()
    for v in "${!CLAUDE_CODE_MESSAGING_@}"; do drop+=(-u "$v"); done # quoted: a name may hold a space or *
    set -m
    (
      set +e
      (cd "$dir" && exec env ${drop[@]+"${drop[@]}"} -u CLAUDECODE \
        -u TMUX -u TMUX_PANE TEAM_ROLE="$id" TEAM_REPO="$REPO" bash -c "$BOOTSTRAP") </dev/null 2>&1 | sed -l 's/^/    | /'
      exit "${PIPESTATUS[0]}"
    ) &
    BOOT_PID=$!
    set +m
    wait "$BOOT_PID" && rc=0 || rc=$?
    BOOT_PID=""
    [ "$rc" -eq 0 ] || setup_failed "repo.bootstrap failed (exit $rc) in $dir"
  fi
  trap - INT TERM HUP
  printf '%s\n' "$real_dir" >"$(setup_mark "$id")"
  BOOT_DIR="" BOOT_NEW=""
}

# Whether real path $1 is $2 or inside it.
inside() { case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac; }

# The real path of the deepest folder of $1 that exists.
deepest_real_dir() {
  local d=$1
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  (cd "$d" && pwd -P)
}

boot_interrupted() {
  trap - INT TERM HUP
  [ -z "$BOOT_PID" ] || kill -TERM -- "-$BOOT_PID" 2>/dev/null || true
  setup_failed "up was interrupted while setting up $BOOT_DIR"
}

setup_failed() {
  trap - INT TERM HUP
  if [ "$BOOT_NEW" = new ]; then
    git -C "$REPO" worktree remove --force "$BOOT_DIR" >/dev/null 2>&1 || echo "  warning: could not remove $BOOT_DIR; remove it before the next up" >&2
    die "$1; the new worktree was removed, so the next up sets it up again"
  fi
  die "$1; the worktree was left as it is (it may hold work) and is not marked set up, so the next up tries again"
}

# The factory checkout this script runs from, and its commit (#189). A team pinned to a release runs
# from a checkout of its own (docs/pinned-release.md), and its seats' say, hooks and plugin come from
# the checkout that started them, so check says which one before a seat is restarted. Only a checkout
# whose top folder is this one counts: an install copied into some other repository is not described
# as that repository. --tags names a lightweight tag too (git tag <name>), which plain describe skips,
# showing only a commit. GIT_OPTIONAL_LOCKS=0 keeps describe --dirty from writing the checkout's index.
install_line() {
  local top real d
  real=$(cd -P "$HERE" && pwd -P)
  top=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$top" ] && [ "$(cd -P "$top" && pwd -P)" = "$real" ] &&
    d=$(GIT_OPTIONAL_LOCKS=0 git -C "$HERE" describe --tags --always --dirty 2>/dev/null); then
    echo "install   : $HERE at $d"
  else
    echo "install   : $HERE (not a git checkout)"
  fi
}

cmd_check() {
  local r on="not mounted" d real users
  mount | grep -qF " on $VOLUME (" && on="mounted"
  install_line
  echo "team file : $CONFIG"
  echo "team      : $TEAM (tmux prefix '$PREFIX')"
  echo "repo      : $GITHUB at $REPO (origin must contain '$GITHUB', base $BASE)"
  echo "project   : $PROJECT_NAME $PROJECT_URL"
  echo "worktrees : $WT_ROOT   [volume $VOLUME: $on]"
  echo "wrapper   : ${WRAPPER:-none (claude runs directly)}"
  local plugin
  plugin=$(cfg get sessions.plugin)
  if [ -n "$plugin" ]; then echo "plugin    : $plugin (skills as /factory:<skill>)"; else echo "plugin    : off (sessions.claude.plugin: false)"; fi
  echo "gate      : $(cfg get repo.gate_summary)"
  echo "prompts   : $(cfg get prompts.summary)"
  prompts_warn=$(cfg get prompts.warning)
  [ -z "$prompts_warn" ] || echo "$prompts_warn"
  hooks_note=$(cfg get hooks.note)
  [ -z "$hooks_note" ] || echo "hooks     : $hooks_note"
  echo "bootstrap : ${BOOTSTRAP:-none}$([ -n "$BOOTSTRAP" ] && echo ' (run in each new worktree before its seat starts)')"
  local copy
  copy=$(printf '%s' "$COPY_PATHS" | paste -sd ',' - | sed 's/,/, /g')
  echo "copy      : ${copy:-none}$([ -n "$copy" ] && echo ' (from the main checkout into each new worktree)')"
  echo "updates   : Claude Code's auto-updater is off in every seat (DISABLE_AUTOUPDATER=1); update by hand, then down and up"
  if resolve_claude; then
    echo "claude    : $CLAUDE_SRC, version $CLAUDE_VERSION; seats run the team's copy $CLAUDE_COPY$([ -x "$CLAUDE_COPY" ] || echo ' (made at the next up)')"
  else
    echo "claude    : $CLAUDE_ERR"
  fi
  # Each copy up has made, with the running seats that use it. Nothing removes them by itself.
  for d in "$STATE"/bin/claude-*; do
    [ -d "$d" ] || continue
    real=$(ruby -e 'print File.realpath(ARGV[0])' "$d/claude" 2>/dev/null)
    users=""
    for r in $ROLES; do
      if alive "$r" && [ "$(seat_exe "$r")" = "$real" ]; then users="$users $r"; fi
    done
    echo "            $d ($(cat "$d/.how" 2>/dev/null || echo '?')):${users:- no running seat}"
  done
  echo "state     : $STATE"
  printf '%-5s %-36s %-18s %-12s %-9s %-24s %-9s %-7s %s\n' ROLE SEAT SESSION MODEL EFFORT MODE MEMORY GATE WORKDIR
  for r in $ROLES; do
    printf '%-5s %-36s %-18s %-12s %-9s %-24s %-9s %-7s %s\n' "$r" "$(title "$r")" "$(session "$r")" "$(cfg role "$r" model)" \
      "$(cfg role "$r" effort)" "$(cfg role "$r" permission_mode)" "$(cfg role "$r" auto_memory)" "$(cfg role "$r" gate)" "$(workdir "$r")"
  done
  echo "(inherit = flag omitted; the seat uses model, effortLevel and permissions.defaultMode from ~/.claude/settings.json)"
  echo "(MEMORY off = Claude Code's auto memory is off in that seat; (inherit) = auto_memory: true, Claude Code's own settings decide)"
  echo
  echo "kickoff (each seat's first message; the label marks it as team configuration, not the owner's voice):"
  for r in $ROLES; do
    TEAM_SCRIPT=$SELF TEAM_LOG=$LOG cfg kickoff "$r" | sed "1s/^/  [$r] /; 2,\$s/^/    /"
  done
  echo
  cfg permissions_report
  cfg warnings
  echo "valid."
}

cmd_up() {
  local want_view=1 started=0 args="" roles r sess dir launch a args_q settings default_ok=0 tdir ndir d gdirs hdirs
  for a in "$@"; do
    case $a in
      --no-view) want_view=0 ;;
      --default-socket) default_ok=1 ;;
      *) args="$args $a" ;;
    esac
  done
  # Before anything else, tmux included: the refusal must not depend on what a tmux call would do.
  [ "$default_ok" = 1 ] || refuse_default_tmux up "start seats"
  roles=${args:-$ROLES}
  command -v tmux >/dev/null || die "tmux not found"
  resolve_claude || die "$CLAUDE_ERR"
  for r in $roles; do check_role "$r"; done
  # Assignments, so a cfg failure stops up here (set -e) rather than leaving the list below short.
  ndir=$(cfg get state.notes_dir)
  tdir=$(cfg get state.triage_dir)
  gdirs=$(cfg get state.generated_dirs)
  hdirs=$(cfg get state.hook_dirs)
  # Every folder up makes or writes under the state folder must be a real folder or not there yet,
  # checked before up makes, writes or starts anything: the generated folders (settings, prompts and
  # launch scripts are written there; bin holds the claude copy the seats run; setup the marks),
  # the folder of this claude copy, the hooks' gate folder (a gated seat's hook makes it), and the
  # notes and triage folders (#148, sec on #141; the rest #168, sec on #165). mkdir -p, chmod and a
  # write follow a symlink, so up would make, chmod or write wherever it points, and the seats' Edit
  # denies name the state-folder path, not the link's target. A plain file at the name is refused
  # too. Only a seat could put one there, so this is hardening; as in seat_lock (#132), the check is
  # not atomic with the mkdir below. bin comes before the copy's folder in it, so a link at bin is
  # the one named. No supported setup links one of these on purpose: TEAM_STATE_DIR moves the whole
  # state folder, which may itself be reached through a link and is not checked here (#168).
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
      die "$d is not a real folder (a symlink, or not a folder): remove it, then run up again"
    fi
  done < <(for a in $gdirs; do echo "$STATE/$a"; done
    dirname "$CLAUDE_COPY"
    for a in $hdirs; do echo "$STATE/$a"; done
    printf '%s\n' "$ndir" "$tdir")
  for a in $gdirs; do mkdir -p "$STATE/$a"; done
  # Progress notes (#5): seats write them, so up only makes the folder and never touches a note.
  mkdir -p "$ndir"
  # The security-triage record folder (#138), when the team has the role that writes it: up only
  # makes it, owner-only, and nothing deletes a record (disposing of one is the owner's call).
  # mkdir -m sets the mode only on a folder it creates, so chmod gives an existing one the mode too.
  [ -z "$tdir" ] || { mkdir -p -m 700 "$tdir" && chmod 700 "$tdir"; }
  ensure_claude_copy
  # Roles start in the order given (file order by default).
  for r in $roles; do
    sess=$(session "$r")
    if alive "$r"; then
      echo "skip   $r: session $sess already exists (left alone)"
      if [ "$(seat_exe "$r")" = REPLACED ]; then
        echo "ATTENTION $r runs a claude executable that has been replaced under it; restart it: $SELF down --yes $r, then $SELF up $r"
      fi
      continue
    fi
    dir=$(workdir "$r")
    if [ "$(wtype "$r")" = worktree ]; then ensure_worktree "$r"; fi
    [ -d "$dir" ] || die "working directory $dir does not exist"
    args_q=""
    while IFS= read -r a; do args_q="$args_q $(printf '%q' "$a")"; done < <(cfg claude_args "$r")

    # Rewritten on every start and left read-only. The old file is removed by its exact path.
    settings="$STATE/settings/$r.json"
    rm -f "$settings"
    cfg settings "$r" >"$settings" || die "could not write $settings"
    chmod 0444 "$settings"

    # The prompt, the kickoff and the launch script are removed by their exact paths too, before
    # each is written: > follows a link at the file, so up would write wherever a link a seat put
    # there points (#194, sec on #174). rm -f removes the link itself, never what it points at.
    rm -f "$STATE/prompts/$r.md" "$STATE/prompts/$r.kickoff" "$STATE/launch/$r.sh"
    TEAM_SCRIPT=$SELF TEAM_LOG=$LOG cfg render "$r" >"$STATE/prompts/$r.md"
    TEAM_SCRIPT=$SELF TEAM_LOG=$LOG cfg kickoff "$r" >"$STATE/prompts/$r.kickoff"
    launch="$STATE/launch/$r.sh"
    {
      echo '#!/usr/bin/env bash'
      printf 'cd %q\n' "$dir"
      echo '# The wrapper holds the macOS privacy grants (Downloads, removable volumes) that a seat'
      echo '# started from tmux has no responsible app for; it passes them to its child. If it is'
      echo '# configured but missing, claude runs directly.'
      printf 'wrapper=%q\n' "$WRAPPER"
      echo '# The user config folder the seat uses is the one its protected-path rules were built for.'
      if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        printf 'export CLAUDE_CONFIG_DIR=%q\n' "$(cfg get claude.config_dir)"
      else
        echo 'unset CLAUDE_CONFIG_DIR'
      fi
      echo '# The auto-updater would reinstall claude under this running seat, after which macOS can no'
      echo '# longer tell which process it is and its privacy grants stop working (#50). Update by hand.'
      echo 'export DISABLE_AUTOUPDATER=1'
      if [ "$(cfg role "$r" auto_memory)" = off ]; then
        echo '# Auto memory is one folder for every worktree of the repo, loaded into every session there,'
        echo '# so a seat would write unreviewed notes for all of them (#71). On with auto_memory: true.'
        echo 'export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1'
      else
        # On: the seat must not inherit the variable from the tmux server's environment (a team
        # started from inside a seat, where it is set), or check's (inherit) would not be true.
        echo 'unset CLAUDE_CODE_DISABLE_AUTO_MEMORY'
      fi
      printf 'claude_bin=%q\n' "$CLAUDE_COPY"
      echo 'if [ -n "$wrapper" ] && [ -x "$wrapper" ]; then run=("$wrapper" "$claude_bin"); else run=("$claude_bin"); fi'
      printf '"${run[@]}"%s --settings %q -n %q \\\n' "$args_q" "$settings" "$sess"
      printf '  --append-system-prompt "$(cat %q)" \\\n' "$STATE/prompts/$r.md"
      printf '  "$(cat %q)"\n' "$STATE/prompts/$r.kickoff"
    } >"$launch"
    chmod +x "$launch"

    tmux new-session -d -s "$sess" -c "$dir" -x 220 -y 50 \
      -e "TEAM_ROLE=$r" -e "TEAM_CONFIG=$CONFIG" -e "TEAM_SCRIPT=$SELF"
    apply_title "$r"
    tmux send-keys -t "=$sess:" "$launch" Enter
    echo "start  $r: $(title "$r") -> tmux session $sess ($dir)"
    started=$((started + 1))
    sleep 1
  done
  # A seat started in a folder Claude Code has not seen stops at a trust dialog (and the first
  # bypass-permissions run at a warning) until a human answers once. Say which seats those are.
  sleep 6
  echo
  for r in $roles; do
    alive "$r" || continue
    if [ "$(box_state "$r" | cut -f1)" != empty ]; then
      echo "ATTENTION $r is not at its input box (a startup dialog?): $SELF attach $r, answer it, detach (ctrl-b d)"
    fi
  done
  echo "Attach with: $SELF attach <role>"
  # Show the team: one iTerm tab with every running seat. A failure here never fails `up`.
  if [ "$started" -gt 0 ] && [ "$want_view" = 1 ] && [ "$VIEW_ITERM" = true ] && [ "${TEAM_VIEW:-1}" != 0 ]; then
    # up's own --default-socket carries over to the view, which applies the same rule (#105).
    if [ "$default_ok" = 1 ]; then set -- --default-socket; else set --; fi
    cmd_view "$@" || echo "warning: could not open the iTerm view (the seats are running; try: $SELF view)" >&2
  fi
}

# Make tmux set the terminal title for this seat while a client is attached, so a pane header (iTerm
# shows it) says which seat it is: "<role> | <title> | <session>". A session option, so it holds
# wherever the seat is attached. '#' starts a tmux format, hence the doubling.
apply_title() {
  local r=$1 sess str
  sess=$(session "$r")
  str="$r | $(title "$r") | $sess"
  tmux set-option -t "=$sess:" set-titles on
  tmux set-option -t "=$sess:" set-titles-string "${str//#/##}"
}

cmd_titles() {
  local r n=0
  case ${1:-} in
    --default-socket) ;;
    '') refuse_default_tmux titles "set the titles of seats" ;;
    *) die "usage: titles [--default-socket]" ;;
  esac
  for r in $ROLES; do
    alive "$r" || continue
    apply_title "$r"
    n=$((n + 1))
  done
  echo "set the terminal title of $n running seat(s)"
}

# Run osascript with a time limit. A macOS Automation permission prompt would otherwise leave it
# waiting forever, and `up` with it.
run_osa() {
  local out p i rc=0
  out=$(mktemp "${TMPDIR:-/tmp}/factory-osa.XXXXXX")
  osascript "$@" >"$out" 2>&1 &
  p=$!
  for i in $(seq 1 60); do
    kill -0 "$p" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$p" 2>/dev/null; then
    kill "$p" 2>/dev/null
    rm -f "$out"
    echo "osascript timed out after 30s (is a macOS Automation permission prompt waiting for iTerm?)" >&2
    return 1
  fi
  wait "$p" || rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

# The AppleScript that builds the tab. Arguments: role ids, the primary first.
#   left:  the primary seat, the full height of the tab
#   right: one row per two of the other seats, rows stacked; with an odd number of seats the last
#          row is one pane across the full width
# Splits are created first and the attach commands typed afterwards, so a pane is not resized
# while its tmux client is starting. iTerm keeps same-direction splits at equal sizes.
view_script() {
  local first=$1 n r rows i a b
  shift
  n=$#
  rows=$(((n + 1) / 2))
  echo 'tell application "iTerm2"'
  echo '  if (count of windows) = 0 then'
  echo '    set w to (create window with default profile)'
  echo '  else'
  echo '    set w to current window'
  echo '    tell w to create tab with default profile'
  echo '  end if'
  echo '  tell w'
  echo '    set s0 to current session of current tab'
  if [ "$n" -gt 0 ]; then
    echo '    tell s0 to set r1 to (split vertically with default profile)'
    r=2
    while [ "$r" -le "$rows" ]; do
      echo "    tell r$((r - 1)) to set r$r to (split horizontally with default profile)"
      r=$((r + 1))
    done
    r=1
    i=1
    while [ "$i" -le "$n" ]; do
      [ $((i + 1)) -le "$n" ] && echo "    tell r$r to set c$r to (split vertically with default profile)"
      i=$((i + 2))
      r=$((r + 1))
    done
  fi
  echo "    tell s0 to write text \"$(attach_cmd "$first")\""
  r=1
  i=1
  while [ "$i" -le "$n" ]; do
    a=${!i}
    echo "    tell r$r to write text \"$(attach_cmd "$a")\""
    if [ $((i + 1)) -le "$n" ]; then
      b=$((i + 1))
      echo "    tell c$r to write text \"$(attach_cmd "${!b}")\""
    fi
    i=$((i + 2))
    r=$((r + 1))
  done
  echo '    select s0'
  echo '  end tell'
  echo '  activate'
  echo '  return id of w'
  echo 'end tell'
}

# Quoted for the user's shell: a bare =name would be expanded by zsh.
attach_cmd() { printf "tmux attach -t '=%s'" "$(session "$1")"; }

# Resize the iTerm window to the usable area of the screen it is on (not the menu bar or Dock).
# Finder's desktop bounds are no use: with two displays they describe one rectangle spanning both.
size_window() {
  local wid=$1 b l t r bt cx cy sb
  b=$(run_osa -e "tell application \"iTerm2\" to get bounds of window id $wid") || return 1
  IFS=', ' read -r l t r bt <<EOF2
$b
EOF2
  cx=$(((l + r) / 2))
  cy=$(((t + bt) / 2))
  sb=$(osascript -l JavaScript "$HERE/lib/screen_bounds.js" "$cx" "$cy") || return 1
  set -- $sb
  run_osa -e "tell application \"iTerm2\" to set bounds of window id $wid to {$1, $2, $3, $4}" >/dev/null
}

cmd_view() {
  local print=0 default_ok=0 list="" ordered r wid a
  for a in "$@"; do
    case $a in
      --print) print=1 ;;
      --default-socket) default_ok=1 ;;
      *) die "usage: view [--print] [--default-socket]" ;;
    esac
  done
  # --print touches no seat, but is refused too: one rule for the whole command (#105).
  [ "$default_ok" = 1 ] || refuse_default_tmux view "open a view of the seats"
  # --print shows the layout for every role in the file, up or not (used by the tests)
  for r in $ROLES; do
    if [ $print -eq 1 ] || alive "$r"; then list="$list $r"; fi
  done
  [ -n "$list" ] || die "no seats are running; start them with: $SELF up"
  # Seats started before titles existed get theirs now (print mode touches nothing).
  if [ $print -eq 0 ]; then for r in $list; do apply_title "$r"; done; fi
  ordered=""
  case "$list " in *" $VIEW_PRIMARY "*) ordered=$VIEW_PRIMARY ;; esac
  for r in $list; do [ "$r" = "$ordered" ] || ordered="$ordered $r"; done
  # shellcheck disable=SC2086
  set -- $ordered
  if [ $print -eq 1 ]; then
    view_script "$@"
    return 0
  fi
  command -v osascript >/dev/null || die "osascript not found (the iTerm view is macOS only)"
  wid=$(run_osa -e "$(view_script "$@")") || { echo "$wid" >&2; return 1; }
  echo "opened an iTerm tab with $# seat(s): $ordered"
  if [ "$VIEW_WINDOW" = full ]; then
    size_window "$wid" || echo "warning: could not resize the iTerm window" >&2
  fi
}

cmd_status() {
  local r sess where d
  # EXE: the claude executable a running seat runs, or REPLACED (restart it: see seat_exe).
  printf '%-5s %-36s %-18s %-6s %s  %s\n' ROLE SEAT SESSION STATE WORKDIR EXE
  for r in $ROLES; do
    sess=$(session "$r")
    d=$(workdir "$r")
    if [ "$(wtype "$r")" = worktree ]; then
      if [ ! -d "$d" ]; then
        where="$d (missing)"
      else
        case $d in "$VOLUME"/*) where="$d" ;; *) where="$d (OFF VOLUME)" ;; esac
      fi
    else
      where=$d
    fi
    printf '%-5s %-36s %-18s %-6s %s  %s\n' "$r" "$(title "$r")" "$sess" "$(alive "$r" && echo up || echo down)" "$where" \
      "$(if alive "$r"; then seat_exe "$r"; else echo -; fi)"
  done
}

# The claude executable seats run: the team's own copy of the shared install, made by up (#50).
# Claude Code's updater, in any session on the machine, replaces the shared file (even with the same
# version), and macOS then cannot identify a seat still running the old file, so the privacy grants
# it runs under (the worktree volume) stop working. A copy that only up writes is never replaced
# under a running seat. Sets CLAUDE_SRC (the shared file), CLAUDE_VERSION and CLAUDE_COPY, or
# CLAUDE_ERR and returns 1.
resolve_claude() {
  local c
  CLAUDE_ERR=""
  if ! c=$(command -v claude); then
    CLAUDE_ERR="claude not found on PATH (or caught in the middle of a reinstall); retry up"
    return 1
  fi
  if ! CLAUDE_SRC=$(ruby -e 'print File.realpath(ARGV[0])' "$c" 2>/dev/null) || [ ! -x "$CLAUDE_SRC" ]; then
    CLAUDE_ERR="$c does not lead to an executable (Claude Code may be in the middle of a reinstall); retry up"
    return 1
  fi
  CLAUDE_VERSION=$("$CLAUDE_SRC" --version 2>/dev/null | awk 'NR == 1 { print $1 }')
  if ! [[ $CLAUDE_VERSION =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    CLAUDE_ERR="could not read the version of $CLAUDE_SRC; retry up"
    return 1
  fi
  CLAUDE_COPY="$STATE/bin/claude-$CLAUDE_VERSION/claude"
}

# Make the copy if it is not there yet: an APFS clone (cp -c: a file of its own that shares the
# original's blocks) where the state folder is on the same file system, else a plain copy. It is
# checked before it is moved into place, so a seat never runs a partial copy. Any failure stops up:
# falling back to the shared file would bring the problem back without a sign.
copy_link() {
  [ ! -L "$CLAUDE_COPY" ] || die "$CLAUDE_COPY is a symlink, not the team's copy of claude: remove that exact link, then run up again"
}
ensure_claude_copy() {
  local dir tmp how
  # A link at the copy would have every seat run whatever it points at, and [ -x ] follows it, so a
  # link is refused, before and after the move below (#194, sec on #174). Only a seat could put one
  # there. The copy's folder is checked to be a real one by cmd_up (#174).
  copy_link
  [ -x "$CLAUDE_COPY" ] && return 0
  dir=$(dirname "$CLAUDE_COPY")
  tmp="$dir/.claude.partial.$$"
  mkdir -p "$dir" 2>/dev/null || die "could not copy claude to $dir (cannot create the folder)"
  # cp writes through a link at the temp name (it is predictable: the pid), so it goes first.
  rm -f "$tmp"
  how=clone
  if ! cp -c "$CLAUDE_SRC" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    how=copy
    cp "$CLAUDE_SRC" "$tmp" 2>/dev/null || { rm -f "$tmp"; die "could not copy $CLAUDE_SRC to $dir (no space, or no permission?)"; }
  fi
  if [ "$(stat -f %z "$tmp")" != "$(stat -f %z "$CLAUDE_SRC")" ] ||
    [ "$("$tmp" --version 2>/dev/null | awk 'NR == 1 { print $1 }')" != "$CLAUDE_VERSION" ]; then
    rm -f "$tmp"
    die "the copy of claude in $dir does not match $CLAUDE_SRC; retry up"
  fi
  chmod 0555 "$tmp"
  # Another up may have made the copy meanwhile, and its seat may already run it: never replace it.
  # macOS mv -n exits 0 even when it does not move, so the temp file still being there is the sign.
  mv -n "$tmp" "$CLAUDE_COPY" || { rm -f "$tmp"; die "could not copy claude to $CLAUDE_COPY"; }
  if [ -e "$tmp" ]; then
    rm -f "$tmp"
    copy_link
    [ -x "$CLAUDE_COPY" ] || die "$CLAUDE_COPY exists but is not a runnable copy of claude; remove that exact file, then retry up"
    return 0
  fi
  rm -f "$dir/.how"
  echo "$how" >"$dir/.how"
  echo "  copied claude $CLAUDE_VERSION to $CLAUDE_COPY ($how)"
}

# The executable a running seat's claude process runs (its real path), REPLACED when the file at
# that path is no longer the one it runs (another file put in its place, or its folder gone), "-"
# when no claude runs in the pane, "?" when it cannot be told. lsof keeps printing the old path
# after a replacement, so the device and inode are what is compared.
seat_exe() {
  local tty pid line
  tty=$(tmux display-message -p -t "=$(session "$1"):" '#{pane_tty}' 2>/dev/null) || { echo "?"; return; }
  pid=$(ps -t "${tty#/dev/}" -o pid=,comm= | awk '$2 ~ /(^|\/)claude(\.exe)?$/ { print $1; exit }')
  [ -n "$pid" ] || { echo "-"; return; }
  # "<device, hex> <inode> <path>" of the claude executable it runs; stat gives the device in decimal.
  line=$(lsof -a -p "$pid" -d txt -FDin 2>/dev/null |
    awk '/^D/ { d = substr($0, 2) } /^i/ { i = substr($0, 2) } /^n/ { n = substr($0, 2); if (n ~ /(^|\/)claude(\.exe)?$/) { print d " " i " " n; exit } }')
  [ -n "$line" ] || { echo "?"; return; }
  set -- $line
  if [ "$(stat -f '%d %i' "${line#* * }" 2>/dev/null)" = "$(printf '%d' "$1" 2>/dev/null) $2" ]; then echo "${line#* * }"; else echo REPLACED; fi
}

# True when a claude process is attached to the seat's terminal. The pane's own command name is
# no use for this: the launcher is a bash script, so tmux reports "bash" while claude runs.
has_claude() {
  local tty
  tty=$(tmux display-message -p -t "=$(session "$1"):" '#{pane_tty}')
  ps -t "${tty#/dev/}" -o comm= | grep -qE '(^|/)claude(\.exe)?$'
}

# The state of a seat's input box. `say` types into a
# seat only when its screen ends with Claude Code's input box; everything else fails closed, so a
# dialog say has never seen is refused like a known one. The box, as Claude Code 2.1.316 draws it
# (captured 2026-10-30; the e2e stand-in, test/e2e/fake-claude.c, draws the same):
#   ──── <session> ───   a rule: U+2500 as wide as the pane, with the session name (claude -n) in it
#   ❯ <text>             the input: ❯ and a no-break space in column 0; more lines indented two spaces
#   ──────────────────   a plain rule
#     <footer>           0 to 8 lines indented two spaces: status line(s), the mode line, notes
# An empty box may show one dim line after the ❯: a hint ('Try "…"', "Press up to edit queued
# messages") or a suggested next prompt. A dialog (permission prompt, menu, trust or held-message
# dialog) replaces the box. A box taller than a full one scrolls: see box_full_rows. Printed as
# "<state><TAB><dim characters in the box><TAB><rows the box shows><TAB><text>". States:
#   empty       the box holds nothing, or only one line drawn entirely dim
#   text        the box holds text: typed by someone, or left by a message that was not sent
#   copy-mode   someone is scrolling the pane (capture-pane would still show the box)
#   unreadable  tmux could not read the pane
#   diff-notice the diff panel's notice pushed the end of the input box off a short pane (#95)
#   unknown     the screen does not end with the input box
box_state() {
  local sess screen
  sess="=$(session "$1"):"
  screen=$(tmux display-message -p -t "$sess" '#{pane_in_mode}' 2>/dev/null) || { printf 'unreadable\t0\t0\t\n'; return; }
  [ "$screen" = 0 ] || { printf 'copy-mode\t0\t0\t\n'; return; }
  screen=$(tmux capture-pane -e -p -t "$sess" 2>/dev/null) || { printf 'unreadable\t0\t0\t\n'; return; }
  printf '%s\n' "$screen" | LC_ALL=C awk -v name="$(session "$1")" '
    function plain(s) { gsub(/\033\[[0-9;]*m/, "", s); sub(/[ \t]+$/, "", s); return s }
    function rule(s) { return s ~ /^(─)+$/ && length(s) >= 60 }   # 20 or more, 3 bytes each
    function top(s) {                                              # a rule, or one naming this seat
      if (rule(s)) return 1
      if (s !~ /^(─)+ [^ ].* (─)+$/) return 0
      sub(/^(─)+ /, "", s); sub(/ (─)+$/, "", s); return s == name
    }
    # Counts the visible characters of s drawn dim (into dimc) and not dim (normc, spaces aside),
    # from the first one after the cursor and no-break space when skip is set. SGR 2 turns dim on, 0
    # and 22 turn it off; the colour forms 38/48/58;5;n and ;2;r;g;b are skipped, so a colour
    # index of 2 is not read as dim.
    function scan(s, skip,    c, np, ps, i, v) {
      if (skip) { i = index(s, "❯\302\240"); s = i ? substr(s, i + 5) : "" }
      while (s != "") {
        if (match(s, /^\033\[[0-9;]*m/)) {
          np = split(substr(s, 3, RLENGTH - 3), ps, ";"); if (np == 0) { isdim = 0 }
          for (i = 1; i <= np; i++) {
            v = ps[i] + 0
            if (v == 38 || v == 48 || v == 58) { i += (ps[i + 1] == 5) ? 2 : 4 }
            else if (v == 0) isdim = 0
            else if (v == 2) isdim = 1
            else if (v == 22) isdim = 0
          }
          s = substr(s, RLENGTH + 1); continue
        }
        c = substr(s, 1, 1); s = substr(s, 2)
        if (c == " " || c == "\t") continue
        if (isdim) dimc++; else normc++
      }
    }
    # The notice of the diff panel (#95), measured on 2.1.316: with the diff panel open (it opens by
    # itself once a seat has changes to show in a pane 110 columns wide or more, and the choice is
    # kept), a pane narrower than 110 columns draws this box above the input box:
    #   ╭──────…──✕─╮
    #   │ Resize your terminal to at least 110 columns to show the diff panel   │
    #   ╰──────…────╯
    # With 14 rows or more the whole input box still shows under it, and the screen reads as usual;
    # but at 14 and 15 a message of two rows or more no longer fits (qa, #109), so the advice is 16.
    # With 13 or fewer, the screen ends at the input row: no bottom rule and no footer, so nothing
    # shows where the box ends, and say cannot deliver safely. True for exactly that screen: the last
    # row is the input row (❯ in column 0) under the top rule of this seat, with the notice right above.
    # It only changes the wording of the refusal; the screen is refused either way.
    function cutnotice() {
      return n >= 5 && line[n] ~ /^❯(\302\240|$)/ && top(line[n - 1]) && line[n - 2] ~ /^╰(─)+╯$/ &&
        line[n - 3] ~ /^│ Resize your terminal to at least [0-9]+ columns to show the diff panel +│$/ &&
        line[n - 4] ~ /^╭(─)+✕─╮$/
    }
    { raw[NR] = $0; p = plain($0); if (p != "") { n++; line[n] = p; at[n] = NR } }
    END {
      j = n
      for (f = 0; j > 0 && !rule(line[j]); j--) {
        if (++f > 8 || line[j] !~ /^  [^ ]/ || line[j] ~ /❯|Enter to|Esc to/) { print (cutnotice() ? "diff-notice" : "unknown") "\t0\t0\t"; exit }
      }
      if (j < 1) { print (cutnotice() ? "diff-notice" : "unknown") "\t0\t0\t"; exit }
      for (k = j - 1; k > 0 && line[k] !~ /^❯/; k--) {
        if (j - k > 60 || line[k] !~ /^  /) { print "unknown\t0\t0\t"; exit }
      }
      if (k < 2 || line[k] !~ /^❯(\302\240|$)/ || !top(line[k - 1])) { print "unknown\t0\t0\t"; exit }
      text = substr(line[k], 4); sub(/^\302\240/, "", text)
      for (i = k + 1; i < j; i++) text = text " " substr(line[i], 3)
      # One line drawn entirely dim comes from Claude Code itself: a hint (Try "…", Press up to
      # edit queued messages) or a suggested next prompt. People and pastes cannot draw dim text, so
      # it counts as empty. Anything else is text. The middle field counts dim characters, which
      # must be 0 once our message is in the box.
      isdim = 0; dimc = 0; normc = 0
      scan(raw[at[k]], 1); for (i = k + 1; i < j; i++) scan(raw[at[i]], 0)
      rows = at[j] - at[k]                          # screen rows, a blank line in the text included
      if (text == "" || (k + 1 == j && normc == 0 && dimc > 0))
        print "empty\t" dimc "\t" rows "\t"
      else
        print "text\t" dimc "\t" rows "\t" text
    }'
}

# Why a message must not be typed into the seat now ($2 is its box state), or nothing.
box_refusal() {
  case ${2%%	*} in
    empty) ;;
    text) echo "the input box of $1 is not empty (someone typing, or an earlier message that was not sent): attach $1 and clear it ($SELF attach $1)" ;;
    copy-mode) echo "$1's pane is in copy mode (someone is scrolling): leave it with q ($SELF attach $1)" ;;
    unreadable) echo "could not read $1's screen" ;;
    diff-notice) echo "$1 shows Claude Code's diff panel notice (\"Resize your terminal to at least 110 columns to show the diff panel\") in a pane too short to show the input box under it: make the pane 110 columns wide or more (the panel then docks beside the transcript), or give it 16 rows or more, or close the diff panel in $1 ($SELF attach $1)" ;;
    *) echo "screen not recognised as ready (a permission prompt, a menu, a dialog?): attach $1 ($SELF attach $1)" ;;
  esac
}

# The most rows the input box of seat $1 shows before it scrolls. Claude Code 2.1.316 (measured
# 2026-10-30 in panes of 12 to 70 rows) grows the box to floor((pane rows - 10) / 2) rows, never
# fewer than 3, then scrolls to keep the cursor, at the end of a pasted message, in view: the first
# visible row then starts with the prompt, mid-message, and nothing marks that rows are hidden. A
# paste of more than 800 characters, or of 4 or more lines, is shown as "[Pasted text #N ...]"
# instead, so only messages below both edges scroll.
box_full_rows() {
  local h
  h=$(tmux display-message -p -t "=$(session "$1"):" '#{pane_height}' 2>/dev/null) || return 1
  h=$(( (h - 10) / 2 )); [ "$h" -lt 3 ] && h=3; echo "$h"
}

# Whether box state $2 of seat $1 shows just the message, label $3 then body $4, after their pastes:
# text with nothing drawn dim, such as a suggestion left next to it, that is the whole message, or
# the label and the placeholder Claude Code shows for a long body and nothing else, or else shows the
# message's end in a full, scrolled box. Whitespace is where the box and the message may differ (the
# box wraps at spaces and box_state joins rows with one), so both are compared with all of it
# removed. Whole: the visible text is the message. It is not enough that it starts with the
# message's "[from <role>]": text typed after the message would go out with it, and a box that
# scrolled in a small pane is whole again once grown (tl on #132).
# Placeholder: this message's own label, then "[Pasted text #N]" or "[Pasted text #N +K lines]", as
# the whole box. Text typed after it, a second paste, a placeholder with no label or with another
# label do not pass (tl on #132 and #150).
# End: the visible text is a suffix of the message of at least 40 characters, and the box shows as
# many rows as it can. A box only scrolls once full, so a shorter box that is not the whole message
# holds something else. The label has scrolled off by then, so this rule cannot see it: deliver_one
# checks it alone (box_has_label) before the body goes in (tl on #175). Text before the message would
# show at the top and text after it at the end, so neither passes, except one gap:
# a draft typed in the moment between the empty-box check and the paste, scrolled out of view by a
# tall message, would go out with it (the README says so). When the box does not show just the
# message, it prints why, so the refusal names the real cause (#84).
box_has_message() {
  local state dim rows vis full m v ph lab
  IFS='	' read -r state dim rows vis <<EOF
$2
EOF
  case $state in
    text) ;;
    empty) echo "the box is empty after the paste (the paste did not reach it)"; return 1 ;;
    unknown) echo "the screen no longer ends with the input box (a dialog came up, or the message grew the box past the bottom of the pane)"; return 1 ;;
    *) box_refusal "$1" "$2"; return 1 ;;
  esac
  [ "$dim" = 0 ] || { echo "dim text was drawn next to the message (a hint or suggestion from Claude Code)"; return 1; }
  m=$(printf '%s%s' "$3" "$4" | LC_ALL=C tr -d '[:space:]'); v=$(printf '%s' "$vis" | LC_ALL=C tr -d '[:space:]')
  [ "$v" != "$m" ] || return 0
  # The label is compared as a string (quoted in ${v#...}), never as a pattern.
  lab=$(printf '%s' "$3" | LC_ALL=C tr -d '[:space:]')
  ph='^\[Pastedtext#[0-9]+(\+[0-9]+lines?)?\]$'
  if [ "${v#"$lab"}" != "$v" ] && [[ ${v#"$lab"} =~ $ph ]]; then return 0; fi
  full=$(box_full_rows "$1") || { echo "could not read the height of $1's pane"; return 1; }
  [ "$rows" = "$full" ] || { echo "the box shows $rows of its $full rows and not just the message, so it holds something else"; return 1; }
  [ "${#v}" -ge 40 ] || { echo "only ${#v} characters of the message's end are visible (short last lines in a narrow pane), under the 40 say needs to recognise it"; return 1; }
  [ "${m%"$v"}" != "$m" ] || { echo "the box does not end with the message: other text is in it"; return 1; }
}

# Whether box state $2 of seat $1 holds just label $3, after the label's paste and before the body's
# (#150, tl on #175): text, nothing drawn dim, and with whitespace removed exactly the label. A body
# that scrolls the box hides the label, so this is the only check that sees it: a label cleared from
# the box (Ctrl-C, Esc) or swallowed would otherwise let the body go out unlabelled, as the owner's.
box_has_label() {
  local state dim rows vis
  IFS='	' read -r state dim rows vis <<EOF
$2
EOF
  case $state in
    text) ;;
    empty) echo "the box is empty after the label's paste (the paste did not reach it)"; return 1 ;;
    unknown) echo "the screen no longer ends with the input box (a dialog came up?)"; return 1 ;;
    *) box_refusal "$1" "$2"; return 1 ;;
  esac
  [ "$dim" = 0 ] || { echo "dim text was drawn next to the label (a hint or suggestion from Claude Code)"; return 1; }
  [ "$(printf '%s' "$vis" | LC_ALL=C tr -d '[:space:]')" = "$(printf '%s' "$3" | LC_ALL=C tr -d '[:space:]')" ] ||
    { echo "the box holds something other than the label"; return 1; }
}

# Short panes (#84). The team view gives seats panes as small as 89x13 (10 seats) or 10 to 11 rows
# (12 seats). Under 110 columns, a seat whose diff panel is open draws a notice above its input
# box, and at 13 rows or fewer that pushes the box off the screen; under 12 rows a paste grows the
# box past the bottom (both measured on 2.1.316, #95 and #73). Most messages still fit (qa on #132),
# so say runs its checks at the pane's own size first. Only when one refuses in a window under
# 110x12 does it grow the window to at least 220x50, the size seats run at detached, where every
# check here was measured and verified live (the diff panel docks beside the transcript, no notice),
# run that same check again, and at the end put back exactly the size and window-size option it
# found (tl on #132). While grown, the owner's view of that seat shows a clipped part of the bigger
# window, for about a second, so a seat whose checks pass is never grown. A window at 110x12 or
# more is never touched.
SAY_MIN_COLS=110 SAY_MIN_ROWS=12 SAY_COLS=220 SAY_ROWS=50
GROWN_WIN="" GROWN_W="" GROWN_H="" GROWN_OPT="" LOCK_WHY=""

# Grows seat $1's window if it is under SAY_MIN_COLS x SAY_MIN_ROWS and not grown yet, recording
# what to put back, and waits for Claude Code to redraw at the new size. True only when it grew the
# window now, so the caller knows a check is worth running again. The traps put it back on every
# exit but SIGKILL; the README names the recovery for that. Bash runs a trap once the command it is
# waiting for returns, and every tmux call here returns at once.
grow_window() {
  local win w h opt i
  [ -z "$GROWN_WIN" ] || return 1
  # The window by its id, not =<session>:, which is whichever window is current when it is put
  # back (tl on #132).
  IFS=' x' read -r win w h <<EOF
$(tmux display-message -p -t "=$(session "$1"):" '#{window_id} #{window_width}x#{window_height}' 2>/dev/null)
EOF
  case "$w$h" in '' | *[!0-9]*) return 1 ;; esac
  case $win in @*) ;; *) return 1 ;; esac
  [ "$w" -lt "$SAY_MIN_COLS" ] || [ "$h" -lt "$SAY_MIN_ROWS" ] || return 1
  # The window's own window-size (empty: unset, so the global one applies). resize-window sets it
  # to manual, so it is put back as found, not unset.
  opt=$(tmux show-options -w -v -t "$win" window-size 2>/dev/null) || opt=""
  GROWN_WIN=$win GROWN_W=$w GROWN_H=$h GROWN_OPT=$opt
  trap 'shrink_window' EXIT
  trap 'shrink_window; exit 129' HUP
  trap 'shrink_window; exit 130' INT
  trap 'shrink_window; exit 143' TERM
  [ "$w" -ge "$SAY_COLS" ] || w=$SAY_COLS
  [ "$h" -ge "$SAY_ROWS" ] || h=$SAY_ROWS
  tmux resize-window -t "$win" -x "$w" -y "$h" 2>/dev/null || return 1
  # Claude Code redraws on SIGWINCH. Until it has, the screen is the old frame, drawn small, which
  # can read as an empty box (tl on #132), so the wait ends only when the box's bottom rule, the
  # last plain rule on the screen, is as wide as the grown window (Claude Code draws it across the
  # pane), or after about 3 seconds. The last one, because growing a pane can bring older, wider
  # lines back into view above the current frame. The check run again decides either way.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 0.2 9>&-
    tmux capture-pane -p -t "$win" 2>/dev/null | LC_ALL=C awk -v w="$w" '
      { sub(/[ \t]+$/, "") } /^(\342\224\200)+$/ { last = length($0) } END { exit last != 3 * w }' && break
  done
  return 0
}

# Puts back what grow_window changed, if anything: the size first (resize-window sets the window's
# window-size to manual), then window-size as it was, set or unset.
# Each tmux call may fail (the window may be gone) without stopping the rest: set -e applies inside
# trap actions too (tl on #132).
shrink_window() {
  [ -n "$GROWN_WIN" ] || return 0
  tmux resize-window -t "$GROWN_WIN" -x "$GROWN_W" -y "$GROWN_H" 2>/dev/null || true
  if [ -n "$GROWN_OPT" ]; then
    tmux set-option -w -t "$GROWN_WIN" window-size "$GROWN_OPT" 2>/dev/null || true
  else
    tmux set-option -w -u -t "$GROWN_WIN" window-size 2>/dev/null || true
  fi
  GROWN_WIN=""
  trap - EXIT HUP INT TERM
}

# One say at a time types into a seat (#84): two pastes would mix in one box, and one say's
# shrink_window could land in the middle of another's delivery. The lock is an flock on
# <state>/say/<role>.lock, held through file descriptor 9 of this shell (macOS has no flock(1), so
# perl takes it on the inherited descriptor). The kernel releases it when this shell exits, however
# it ends, SIGKILL included, so a dead holder leaves no lock behind; the children here close 9 or
# end at once. Waits up to 8 seconds, then refuses: sets LOCK_WHY and returns 1. It must run in
# the calling shell, never in $(...), or the descriptor and the lock would go with the subshell.
# The path must be a plain file or not there yet (sec on #132): something else could be put there,
# and opening a FIFO to append blocks with no limit. It is opened read-write, which does not block
# even on a FIFO swapped in after the check; flock then fails there, and the wait runs out.
seat_lock() {
  local f="$STATE/say/$1.lock" rc
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
    LOCK_WHY="$f is not a regular file: remove it"
    return 1
  fi
  mkdir -p "$STATE/say" 2>/dev/null && exec 9<>"$f" || { LOCK_WHY="could not open $f"; return 1; }
  rc=0
  perl -MFcntl=:flock -e 'open(my $f, "+<&=", 9) or exit 70; for (1 .. 80) { exit 0 if flock($f, LOCK_EX | LOCK_NB); select(undef, undef, undef, 0.1) } exit 75' || rc=$?
  [ "$rc" = 0 ] && return 0
  exec 9>&-
  if [ "$rc" = 75 ]; then
    LOCK_WHY="another say is typing into $1 and did not finish within 8 seconds; try again"
  else
    LOCK_WHY="could not take the lock on $f (perl exited $rc)"
  fi
  return 1
}
seat_unlock() { exec 9>&-; }

# Deliver one message, label $2 ("[from <role>] ") and body $3, by bracketed paste (safe for
# multi-line text), then Enter. If the seat is mid-turn the text queues in its input box and is
# submitted by the Enter all the same.
send_one() {
  local to=$1 label=$2 body=$3 sess rc
  sess=$(session "$to")
  if ! alive "$to"; then
    echo "not delivered: $to is down ($sess)" >&2
    return 1
  fi
  # Never type into a seat that is not ready to take a message. At a shell, the text would run
  # as a command. At a dialog the Enter would pick the highlighted answer.
  if ! has_claude "$to"; then
    echo "not delivered: $to has no claude process running (its pane is at a shell)" >&2
    return 1
  fi
  if ! seat_lock "$to"; then
    echo "not delivered: $LOCK_WHY" >&2
    return 1
  fi
  deliver_one "$to" "$label" "$body" "$sess"; rc=$?
  shrink_window
  seat_unlock
  return "$rc"
}

# Whether a check that refused on box state $1 may pass in a bigger window: not when someone is
# scrolling the pane or tmux cannot read it, where growing would only flash the owner's view.
size_may_matter() {
  case ${1%%	*} in copy-mode | unreadable) return 1 ;; esac
}

# The checks, the paste and the Enter, for send_one, which holds the seat's lock. A check that
# refuses in a small window grows it (grow_window, at most once per say) and runs again; only its
# second answer counts, and send_one puts the window back (#84, tl on #132). In #84's own case the
# box is whole before the paste and it is the check after the paste that refuses.
deliver_one() {
  local to=$1 label=$2 body=$3 sess=$4 buf st why ok
  st=$(box_state "$to"); why=$(box_refusal "$to" "$st")
  if [ -n "$why" ] && size_may_matter "$st" && grow_window "$to"; then
    st=$(box_state "$to"); why=$(box_refusal "$to" "$st")
  fi
  if [ -n "$why" ]; then
    echo "not delivered: $why" >&2
    return 1
  fi
  # The label and the body go in as two pastes (#150). Claude Code shows a long body as "[Pasted text
  # #N ...]" and hands it to the seat inside <pasted_content> tags; a label inside that block made
  # seats doubt who sent it (fs1's live runs on #150: a seat declining a suspicious request replied to
  # the labelled sender 0 times in 5, against 8 in 10 with the label outside). A paste as short as
  # the label is never collapsed, so it stays the seat's own text, before the block. It is pasted,
  # not typed: in the window described below, typed keys could answer a dialog (role ids hold
  # digits, and "1" is often Yes), while a paste cannot (tl on #150). An empty body has no second
  # paste: tmux makes no buffer of nothing, and the label is then the whole message.
  buf="team-$$-$to"
  if ! { printf '%s' "$label" | tmux load-buffer -b "$buf" - && tmux paste-buffer -p -d -b "$buf" -t "=$sess:"; }; then
    tmux delete-buffer -b "$buf" 2>/dev/null || true
    echo "not delivered: could not paste into the input box of $to (tmux failed)" >&2
    return 1
  fi
  # The body goes in only once the box holds just the label (box_has_label, tl on #175), so it cannot
  # go out without it. A small window is grown for this check as for the others. Still open: the label
  # cleared in the moment between this check and the body's paste.
  sleep 0.5 9>&-
  st=$(box_state "$to"); ok=1; why=$(box_has_label "$to" "$st" "$label") || ok=0
  if [ "$ok" = 0 ] && size_may_matter "$st" && grow_window "$to"; then
    st=$(box_state "$to"); ok=1; why=$(box_has_label "$to" "$st" "$label") || ok=0
  fi
  if [ "$ok" = 0 ]; then
    echo "not delivered: the input box of $to does not show just the message's label after its paste${why:+ ($why)}, so the message was not pasted; text left in input box, if any: it goes out with the next Enter" >&2
    return 1
  fi
  if [ -n "$body" ] && ! { printf '%s' "$body" | tmux load-buffer -b "$buf" - && tmux paste-buffer -p -d -b "$buf" -t "=$sess:"; }; then
    tmux delete-buffer -b "$buf" 2>/dev/null || true
    echo "not delivered: the message's label was pasted into $to but the message was not (tmux failed); text left in input box: it goes out with the next Enter" >&2
    return 1
  fi
  sleep 0.5 9>&-
  # Enter only when the box now holds just this message (box_has_message), so the Enter can only
  # submit the message. Otherwise a dialog came up, or the paste went nowhere. Still open: a dialog
  # that appears between the first check and the paste (the paste then lands in it; this check sees
  # no box and sends no Enter), and one that appears after this check, before the Enter. When this
  # check refuses in a small window, the text is already in the box: the window is grown and the
  # check runs again on the screen as redrawn, and only a pass there sends the Enter.
  st=$(box_state "$to"); ok=1; why=$(box_has_message "$to" "$st" "$label" "$body") || ok=0
  if [ "$ok" = 0 ] && size_may_matter "$st" && grow_window "$to"; then
    st=$(box_state "$to"); ok=1; why=$(box_has_message "$to" "$st" "$label" "$body") || ok=0
  fi
  if [ "$ok" = 0 ]; then
    echo "not delivered: the input box of $to does not show the message after the paste${why:+ ($why)}; text left in input box: it goes out with the next Enter" >&2
    return 1
  fi
  tmux send-keys -t "=$sess:" Enter
}

# One messages.log field, escaped so a record stays on one line and the terminal reading the log
# with tail cannot be driven by the message (an ESC or CSI sequence could retitle it or hide lines;
# a bidi override could reorder how the line shows): backslash becomes \\, newline \n, CR \r, tab
# \t, and every other C0 control, DEL, C1 control (U+0080-U+009F) and bidi embedding, override or
# isolate (U+202A-U+202E, U+2066-U+2069) is written as its UTF-8 bytes in \xHH form. This goes by
# code point, not by byte: the check mark is E2 9C 93, and 0x9C alone is a C1 control. Text that is
# not valid UTF-8 has every byte from 0x80 up escaped instead, so a stray 0x9B cannot act as CSI.
# Reversible: printf '%b' gives back the original. --disable-gems: RubyGems is not needed, and its
# loading has failed in an unreadable working directory. If ruby fails, a fixed marker is logged
# rather than an empty field.
log_field() {
  ruby --disable-gems -e '
    s = ARGV[0].dup.force_encoding("UTF-8")
    re = s.valid_encoding? ? /[\\\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/ : (s = s.b; /[\\\x00-\x1f\x7f-\xff]/n)
    esc = { "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }
    print s.gsub(re) { |c| esc[c] || c.bytes.map { |b| format("\\x%02X", b) }.join }' -- "$1" || printf '%s' '<log_field failed>'
}

# The role of the seat this process runs inside, or nothing when it runs outside every seat. Used
# when TEAM_ROLE is unset (a cleared or rebuilt environment: env -i, a sanitising script), so that
# say from inside a seat is not labelled [from owner] (#41). It walks this process's ancestors and
# compares each one's controlling tty with the seats' pane ttys. The ancestors are walked, not only
# this process, because Claude Code's Bash tool runs commands in a child that has left the pane's
# terminal: that child and its descendants have no tty, but the claude process above them still
# holds its pane's tty. A pane that is not a seat's (the owner's own tmux pane) matches no seat.
#
# It fails closed (status 1, the reason on stdout) whenever it cannot tell (#97):
# - ps cannot read this process or any of its ancestors;
# - the walk reads 100 processes without reaching pid 1 (#130), so it has not seen them all;
# - an ancestor has a tty but tmux cannot list its panes (only a process with no tty and no tmux
#   server above it is taken to be outside tmux);
# - the tty is a pane of a seat of another team on this server (its session sets TEAM_ROLE, as up
#   sets it for every seat), which is a seat but has no role in this team to be labelled with;
# - a tmux server is among the ancestors and it is not the server say addresses (#115): this runs
#   in a pane of another server, whose seats this server's pane list cannot show. That covers a seat
#   of any team on any other server, and also the owner's own pane there, who can run say from a
#   terminal outside tmux instead (TEAM_ROLE=owner is refused). A live-test driver sets
#   TEAM_ROLE=live-test (test/live-env.sh run does), so this check does not apply to it.
#
# This catches mislabelling by accident only, and labels are not authenticated (#29). A process
# escapes the check whenever, when it runs, none of its ancestors is a tmux server other than the
# one say addresses and none holds the tty of a seat's pane on that one: a process that leaves the
# session (setsid) and outlives its parent; any background job (`&`, nohup, disown) that outlives
# the tool call that started it, since its parent exits and it is re-parented to launchd; anything
# started by launchd or cron; and a command in a new tmux session or window, or a `tmux run-shell`,
# that a seat starts on the server say addresses, whose ancestor is that server and whose session
# does not set TEAM_ROLE. All of these are labelled [from owner].
#
# A pane belongs to a seat when its session has the seat's session name; nothing checks that up
# started that session (#97). That is deliberate: say delivers to a seat by the same session name,
# so a session holding that name is the seat as far as say is concerned, and a stricter test (the
# session's TEAM_ROLE) is one anyone able to create the session can pass too.
caller_seat() {
  local pid=$$ ppid tty comm ttys="" srvs="" panes line srv sess name n=0 r
  local adv="set TEAM_ROLE to your role id"
  while [ "$pid" -gt 1 ] && [ $n -lt 100 ]; do
    # comm last: a command's name may hold spaces, and read gives the last field the rest.
    read -r ppid tty comm < <(ps -o ppid=,tty=,comm= -p "$pid" 2>/dev/null) || ppid=""
    # A walk ends at pid 1 without asking ps, so ps failing at any depth means it could not read
    # this process or an ancestor (one that exited mid-walk, say): refuse, whatever ttys were seen.
    if [ -z "$ppid" ]; then
      [ $n -eq 0 ] && echo "ps could not read this process, so say cannot tell whether it runs inside a seat; $adv" ||
        echo "ps could not read an ancestor of this process (pid $pid), so say cannot tell whether it runs inside a seat; $adv"
      return 1
    fi
    case $tty in ""|"?"|"??") ;; *) ttys="$ttys ${tty#/dev/} " ;; esac
    # A tmux server: macOS shows the executable's name, and Linux may show the title it sets
    # ("tmux: server").
    case ${comm##*/} in tmux|tmux:*|"tmux "*) srvs="$srvs $pid" ;; esac
    pid=$ppid; n=$((n + 1))
  done
  # The walk stopped at its cap, not at pid 1 (#130): the processes above were never read, and any of
  # them could hold a seat's tty or be another tmux server, so refuse rather than take this for owner.
  if [ "$pid" -gt 1 ]; then
    echo "the walk up this process's ancestors stopped at its cap of 100 processes (at pid $pid) before reaching pid 1, so say cannot tell whether it runs inside a seat; $adv"
    return 1
  fi
  [ -n "$ttys$srvs" ] || return 0
  # Each line is "<server pid> <pane tty> <session name>". #{pid} is the pid of the server this
  # list comes from, the one say addresses, so no other tmux command is needed to learn it.
  panes=$(tmux list-panes -a -F '#{pid} #{pane_tty} #{session_name}' 2>/dev/null) ||
    { echo "tmux could not list its panes, so say cannot tell whether this runs inside a seat; $adv"; return 1; }
  srv=${panes%%$'\n'*}; srv=${srv%% *}
  if [ -n "$srvs" ]; then
    case $srv in ""|*[!0-9]*) echo "tmux did not report its server's pid, so say cannot tell whether this runs inside a seat; $adv"; return 1 ;; esac
    for r in $srvs; do
      [ "$r" = "$srv" ] && continue
      echo "this runs inside a pane of another tmux server (pid $r) than the one say addresses (pid $srv), whose seats say cannot see; $adv, or run say from a terminal outside tmux"
      return 1
    done
  fi
  # Each line is split at its spaces with parameter expansion, not with read: read drops leading
  # blanks, so a pane with an empty tty would shift the session name into the tty field. The
  # session name may hold spaces. A pane with no tty matches no caller: an empty tty would match
  # any tty list that has two spaces in a row, which every list of two or more ttys has.
  for r in $ROLES; do
    sess=$(session "$r")
    while IFS= read -r line; do
      line=${line#* }; tty=${line%% *}; name=${line#* }
      [ -n "$tty" ] && [ "$name" = "$sess" ] || continue
      case $ttys in *" ${tty#/dev/} "*) echo "$r"; return 0 ;; esac
    done <<<"$panes"
  done
  while IFS= read -r line; do
    line=${line#* }; tty=${line%% *}; name=${line#* }
    [ -n "$tty" ] || continue
    case $ttys in *" ${tty#/dev/} "*) ;; *) continue ;; esac
    r=$(tmux show-environment -t "=$name" 2>/dev/null) ||
      { echo "tmux could not read the environment of session '$(log_field "$name")', so say cannot tell whether this runs inside a seat; $adv"; return 1; }
    case $'\n'$r in *$'\nTEAM_ROLE='*)
      echo "this runs inside session '$(log_field "$name")', a seat of another team (its session sets TEAM_ROLE); $adv"; return 1 ;;
    esac
  done <<<"$panes"
}

# Why a sender set in TEAM_ROLE may not send, or nothing when it may (#89). The value becomes the
# message's [from <role>] label, so only a role id of this team is taken: anything else (a typo, a
# role of another team, a value with control characters or brackets that would draw a different
# label) is refused rather than shown. owner and launcher are refused even if a team file names
# them as roles: [from owner] is the owner's (given only when TEAM_ROLE is unset, outside every
# seat) and [from launcher] is the kickoff's. The value is shown escaped, never as it is.
#
# live-test is the one sender that is not a role id (#115): test/live-env.sh run sets it, so a live
# test driven from a seat says [from live-test] rather than being refused or labelled owner. A role
# id cannot hold a hyphen, so no seat can have it. It is refused when say addresses the default tmux
# server, where the real team runs, so that team never sees it. This is worked out from TMUX and
# TMUX_TMPDIR alone (tmux_socket), before say runs any tmux command; a real team the owner runs
# on another server is not told apart from a test team and can still receive it.
sender_refusal() {
  local r
  case $1 in
    owner) echo "TEAM_ROLE 'owner' is reserved: [from owner] is used only when TEAM_ROLE is unset, outside every seat"; return ;;
    launcher) echo "TEAM_ROLE 'launcher' is reserved for the kickoff's [from launcher] label"; return ;;
    live-test)
      [ "$(tmux_socket)" != "$(default_tmux_socket)" ] ||
        echo "TEAM_ROLE 'live-test' is for live tests on a private tmux server (test/live-env.sh run), and this say addresses the default tmux server ($(default_tmux_socket)), where the real team runs"
      return ;;
  esac
  for r in $ROLES; do [ "$r" = "$1" ] && return; done
  echo "TEAM_ROLE '$(log_field "$1")' is not a role id of this team (roles: $ROLES); set it to your role id"
}

cmd_say() {
  # Before anything else, tmux, caller_seat and the log included (#105).
  if [ "${1:-}" = --default-socket ]; then shift; else refuse_default_tmux say "type into seats"; fi
  local to=${1:-} from=${TEAM_ROLE:-} why="" label r rc=0 lrc=0 held out=""
  [ -n "$to" ] && [ $# -ge 2 ] || die "usage: say <role|all> <message...>"
  [ "$to" = all ] || check_role "$to"
  shift
  # An empty or whitespace-only message (a script bug, an unset variable) would go out as a bare label,
  # a turn of its own in the seat (#157). It is refused here, before caller_seat's tmux calls, and
  # logged like any refusal. With TEAM_ROLE unset the sender is logged as '?', since telling a seat
  # from the owner takes those tmux calls. The check reads "$*", what is sent and logged: on bash 3.2
  # "${*:2}" holds \177 for each empty argument. A case pattern, because ${m//[[:space:]]/} takes
  # seconds on a long message (tl on #202).
  case "$*" in
    *[![:space:]]*) ;;
    *) why="the message is empty or only whitespace; give say the text to send"; from=${from:-?} ;;
  esac
  if [ -n "$why" ]; then
    :
  # Inside a seat, a message without TEAM_ROLE goes out under that seat's role, never as the owner's.
  elif [ -z "$from" ]; then
    # A refusal goes through the logged path below like any other (#97), under the sender '?'. The
    # reason says what to do.
    if from=$(caller_seat); then from=${from:-owner}; else why=$from; from='?'; fi
  else
    why=$(sender_refusal "$from")
  fi
  [ -z "$why" ] && [ "$to" = "$from" ] && why="a seat cannot message itself"
  # The label is pasted on its own, before the message (deliver_one, #150).
  label="[from $from] "
  mkdir -p "$STATE"
  # The log is appended to with >>, which follows a link (#194, sec on #174): a seat could put one at
  # messages.log after up, and every say's line would then be written wherever it points (and a FIFO
  # there would hang say). So say refuses before it delivers anything (fail closed), writes no line,
  # and the note at the end says so. The check is not atomic with the append, so it is made again
  # just before it. Anything else that cannot be appended to (a folder, a file without write
  # permission) fails the append itself, after the delivery, as before (#128).
  if log_unsafe && [ -z "$why" ]; then
    why="$LOG is a symlink, a FIFO or a hard link, and say does not write through one: report it to the EM (only a seat could have put it there; it is removed by its exact path)"
  fi
  # Record before report (#128): the messages.log line is written before any terminal message.
  # The log is the record the owner and the EM go by. A write to the terminal or a pipe can fail:
  # EINTR under heavy load (#101), a closed stderr, or a reader that has gone, which kills say with
  # SIGPIPE. Under set -e a failed write ends say on the spot, and say can also be interrupted
  # between two writes. Reporting first could therefore lose the record of a refusal, while the
  # log (a regular file) is not exposed to any of that. So what send_one prints, its "not delivered"
  # reasons, is held in a file and shown after the log line. The file is unlinked as soon as it is
  # open, so nothing is left behind however say ends. send_one runs in this shell, not in $(...),
  # so that its signal traps and seat lock (#84) belong to say itself. If the file cannot be made
  # or opened, send_one prints straight to stderr, as before. mktemp, not a fixed name: it creates
  # the file with O_EXCL, so a symlink or FIFO put at the name beforehand is refused rather than
  # followed (truncating its target) or blocked on (sec on #137).
  held=$(mktemp "$STATE/say.XXXXXXXX" 2>/dev/null) || held=""
  if [ -n "$held" ]; then
    if exec 7>"$held" 8<"$held"; then rm -f "$held"; else rm -f "$held"; held=""; fi
  fi
  if [ -n "$why" ]; then
    rc=1
  elif [ "$to" = all ]; then
    for r in $ROLES; do
      [ "$r" = "$from" ] && continue
      alive "$r" || continue
      say_send "$r" "$label" "$*" || rc=1
    done
  else
    say_send "$to" "$label" "$*" || rc=1
  fi
  # The log records what happened, not what was attempted: a refused delivery says so. One line
  # per say (all included), in the format the README documents under "The message log". $to is a
  # role id or all; $from comes from TEAM_ROLE, which nothing validates, so it is escaped too.
  # A failed append must not lose the terminal message in turn, so it is noted, not fatal, here.
  if log_unsafe; then
    lrc=1
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$(log_field "$from")" "$to" \
      "$([ "$rc" -eq 0 ] && echo delivered || echo NOT-DELIVERED)" "$(log_field "$*")" >>"$LOG" || lrc=$?
  fi
  # Read in full before writing, so that nothing is written to the terminal when nothing was held.
  [ -z "$held" ] || { out=$(cat <&8); exec 7>&- 8<&-; }
  if [ -n "$why" ]; then echo "not delivered: $why" >&2; fi
  if [ -n "$out" ]; then printf '%s\n' "$out" >&2; fi
  # The note says whether the message went out, so that a caller seeing exit 1 does not send a
  # delivered message again (sec on #137).
  if [ "$lrc" != 0 ]; then
    if [ "$rc" = 0 ]; then out=delivered; elif [ "$to" = all ]; then out="not delivered to every seat"; else out="not delivered"; fi
    echo "say: this say's record could not be written to $LOG$(log_unsafe && echo ', a symlink, a FIFO or a hard link') (the message was $out)" >&2
    return 1
  fi
  return "$rc"
}

# The file (messages.log when none is named) is something say must not append to (#194): a symlink
# (to anywhere, -L tests the link itself); a FIFO, which >> would block on; or a hard link, a regular
# file to every other test here that shares its data with another name (tl and sec on #206). The real
# log never has a second link. The argument lets another append-only state file reuse the guard (#216).
log_unsafe() {
  local f=${1:-$LOG}
  [ -L "$f" ] || [ -p "$f" ] || { [ -f "$f" ] && [ "$(stat -f %l "$f" 2>/dev/null || echo 1)" -gt 1 ]; }
}

# send_one, with what it prints held for cmd_say to show after the log line (#128).
say_send() {
  if [ -n "$held" ]; then send_one "$@" 2>&7; else send_one "$@"; fi
}

cmd_attach() {
  if [ "${1:-}" = --default-socket ]; then shift; else refuse_default_tmux attach "attach to a seat"; fi
  local r=${1:-}
  [ -n "$r" ] || r=${ROLES%% *}
  check_role "$r"
  alive "$r" || die "$r is down"
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "=$(session "$r")"; else tmux attach -t "=$(session "$r")"; fi
}

# The pids of the processes whose working folder is folder $1 or inside it, one line, from lsof
# (macOS prints every process's cwd, physically resolved, in about half a second). Returns 2 when
# lsof cannot answer: it lists itself at least, so an empty list means it failed. Returns 3 for a
# path lsof would not print as it is: lsof escapes a backslash as two and, depending on the locale,
# a tab as backslash-t, so such a path would never match and the process would be missed. A path
# of printable ASCII without a backslash is printed unchanged, and so is that prefix of any folder
# inside it, whatever that folder is named.
cwd_users() {
  local p out
  p=$(CDPATH= cd -- "$1" 2>/dev/null && pwd -P) || return 2
  # A newline too: grep reads lines, so it would never see one (lsof prints it as backslash-n).
  case $p in *\\* | *$'\n'*) return 3 ;; esac
  # A here-string, not a pipe: under pipefail, grep -q stopping early could fail the printf.
  LC_ALL=C grep -q '[^ -~]' <<<"$p" && return 3
  out=$(lsof -w -d cwd -F pn 2>/dev/null) || true
  [ -n "$out" ] || return 2
  # The path goes in through the environment: awk -v would read escapes in it ("\t" as a tab), and a
  # path that no longer matches would hide the process.
  printf '%s\n' "$out" | P=$p awk '
    BEGIN { p = ENVIRON["P"] }
    /^p/ { pid = substr($0, 2) }
    /^n/ { n = substr($0, 2); if (n == p || index(n, p "/") == 1) printf "%s%s", (c++ ? " " : ""), pid }
    END { if (c) print "" }'
}

# Remove worktrees that are registered under a team role's folder name but are not at the
# configured location. Bounded by construction: only a clean worktree, with no branch checked
# out and HEAD already contained in the base ref, is removed, so nothing it holds can be lost
# except ignored files (node_modules, build output), which a fresh install recreates. And never one
# that a running process works in (#121): `alive` asks only the tmux server this command reaches,
# so a seat started from another server (or from a copy of the team file with another prefix) looks
# down. The working folders are checked last, right before the removal, so a seat started while
# migrate ran is still seen. A process that enters the folder after that check is not.
#
# #105's rule (refuse a team file outside teams/ on the default tmux server) is not applied here: it
# acts only on the default server, while the gap #121 found is on a private server, which that rule
# lets through by design. The working-folder check holds on any server, and for a copy with another
# session prefix too, whose `alive` misses the real seats even on the default server.
cmd_migrate() {
  local roles=${*:-$ROLES} r p s b dir name moved=0 users cu
  for r in $roles; do check_role "$r"; done
  require_worktree_list
  for r in $roles; do
    [ "$(wtype "$r")" = worktree ] || continue
    dir=$(workdir "$r")
    name=$(cfg role "$r" worktree_name)
    # Each path is ended by a NUL and acted on whole (#134); $s is how it is shown, escaped.
    while IFS= read -r -d '' p; do
      [ -n "$p" ] || continue
      s=$(log_field "$p")
      if alive "$r"; then echo "skip   $r: seat is up; stop it first ($SELF down --yes $r)"; continue; fi
      if [ ! -d "$p" ]; then echo "skip   $r: $s is registered but missing (run: git -C $REPO worktree prune)"; continue; fi
      if [ -n "$(git -C "$p" status --porcelain)" ]; then echo "REFUSE $r: $s has uncommitted or untracked files"; continue; fi
      # The branch name is shown escaped too: git refuses ESC and a newline in a ref name, but takes a
      # C1 control or a bidi override, which would reorder the line on a terminal. set -e: a failing
      # assignment would end the script, so a git that cannot read the branch gives "" as the old test
      # did, and the HEAD check below then refuses.
      b=$(git -C "$p" branch --show-current) || b=""
      if [ -n "$b" ]; then echo "REFUSE $r: $s has branch '$(log_field "$b")' checked out; move that work by hand"; continue; fi
      if ! git -C "$p" merge-base --is-ancestor HEAD "$BASE"; then echo "REFUSE $r: $s HEAD is not contained in $BASE (unpushed commits)"; continue; fi
      # set -e: a failing $(...) assignment would end the script, so its status is caught here.
      cu=0; users=$(cwd_users "$p") || cu=$?
      case $cu in
        0) ;;
        3) echo "REFUSE $r: cannot tell whether a running process works in $s: lsof escapes characters in its path (a backslash, a control or non-ASCII character); remove it by hand"; continue ;;
        *) echo "REFUSE $r: cannot tell whether a running process works in $s (lsof gave no answer)"; continue ;;
      esac
      if [ -n "$users" ]; then echo "REFUSE $r: $s is the working folder of a running process (pid $users); stop it first"; continue; fi
      git -C "$REPO" worktree remove "$p"
      echo "moved  $r: removed $s; '$SELF up $r' recreates it at $dir"
      moved=$((moved + 1))
    done < <(other_worktrees_named "$name" "$dir")
  done
  echo "removed $moved worktree(s)."
  echo "Other worktrees of $REPO that this team does not manage (left alone):"
  while IFS= read -r -d '' p; do
    [ "$p" = "$REPO" ] && continue
    case $p in "$WT_ROOT"/*) continue ;; esac
    echo "  $(log_field "$p")"
  done < <(worktree_paths)
}

cmd_down() {
  local yes=0 default_ok=0 roles="" a r
  for a in "$@"; do
    case $a in
      --yes) yes=1 ;;
      --default-socket) default_ok=1 ;;
      *) roles="$roles $a" ;;
    esac
  done
  # With or without --yes: even the dry run lists the real seats (#105).
  [ "$default_ok" = 1 ] || refuse_default_tmux down "stop seats"
  roles=${roles:-$ROLES}
  for r in $roles; do check_role "$r"; done
  for r in $roles; do
    alive "$r" || continue
    if [ $yes -eq 1 ]; then
      tmux kill-session -t "=$(session "$r")"
      echo "killed $r ($(session "$r"))"
    else
      echo "would kill $r ($(session "$r")); rerun with --yes"
    fi
  done
}

case "${1:-}" in
  check) cmd_check ;;
  up) shift; cmd_up "$@" ;;
  status) cmd_status ;;
  view) shift; cmd_view "$@" ;;
  titles) shift; cmd_titles "$@" ;;
  say) shift; cmd_say "$@" ;;
  attach) shift; cmd_attach "$@" ;;
  migrate) shift; cmd_migrate "$@" ;;
  down) shift; cmd_down "$@" ;;
  *) sed -n '3,39p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
