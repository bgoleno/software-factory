# Sourced by test/e2e.sh, in its shell and in the order of AREAS there (#70); not run alone.
# The generated settings files: merged rules, protected paths, auto memory, the seats' claude copy, notes;
# the security-triage record folder (#138); the auto-updater off in every seat and nowhere else.
# Uses the running seats. Restarts em.
echo "--- generated settings"
# The user's rules, in team-then-role order, without duplicates. Rules the launcher adds itself
# (Edit denies on its own files, the Read rules on the log and the triage folder, and the Read denies
# on the log, triage records and notes of secstate, the e2e's other team beside $T/state, #197) are
# checked separately, so they are left out of these lists.
perms() { ruby -rjson -e 'p = JSON.parse(File.read(ARGV[0]))["permissions"] || {}; %w[deny ask allow].each { |k| l = (p[k] || []).reject { |r| r.start_with?("Edit(//", "Bash(git push ") || r =~ %r{\ARead\(//.*/state/(messages\.log|triage/\*\*)\)\z} || r =~ %r{\ARead\(//.*/secstate/(messages\.log|triage/\*\*|notes/\*\*)\)\z} }; puts "#{k}=#{l.join(" | ")}" }; puts "disable=#{p["disableBypassPermissionsMode"]}"' "$1" 2>&1; }
# rules <file> <deny|ask|allow>: one rule per line
rules() { ruby -rjson -e 'puts((JSON.parse(File.read(ARGV[0]))["permissions"] || {})[ARGV[1]] || [])' "$1" "$2"; }
want_em='deny=Read(//**/.env) | Bash(touch tt-deny*)
ask=Bash(gh pr merge *)
allow=Bash(npm test)
disable='
want_w1='deny=Read(//**/.env) | Bash(touch tt-deny*) | Bash(gh pr merge *)
ask=
allow=Bash(npm test) | Bash(make *)
disable=disable'
[ "$(perms $T/state/settings/em.json)" = "$want_em" ] && ok "em.json: the team rules only" || { bad "em.json rules"; perms $T/state/settings/em.json; }
[ "$(perms $T/state/settings/w1.json)" = "$want_w1" ] && ok "w1.json: team + role merged, duplicate dropped, team ask shadowed by the role deny dropped, bypass disabled for a non-bypass mode" || { bad "w1.json rules"; perms $T/state/settings/w1.json; }
[ "$(stat -f %Lp $T/state/settings/em.json)" = 444 ] && ok "settings file is read-only (0444)" || bad "settings file mode $(stat -f %Lp $T/state/settings/em.json)"
# Edit denies the launcher adds for files that change a seat's next start or its live rules. Paths
# are real paths (the temp folder is under a symlink on macOS).
RT=$(cd $T && pwd -P); RSRC=$(cd $SRC && pwd -P); RW1=$(cd $VOL/$ROOT/team-w1 && pwd -P); RHC=$(cd ~/.claude && pwd -P); RH=$(cd ~ && pwd -P)
missing=""
for p in "$RT/state/settings/**" "$RT/state/launch/**" "$RT/state/prompts/**" "$RT/state/messages.log" "$RT/team.yaml" \
  "$RSRC/roles/common.md" "$RSRC/factory.sh" "$RSRC/lib/**" "$RSRC/roles/**" "$RSRC/plugin/**" "$RT/bin/wrap" \
  "$RT/repo/.claude/settings.json" "$RT/repo/.claude/settings.local.json" "$RT/repo/.claude/skills/**" "$RT/repo/.claude/agents/**" "$RT/repo/.claude/commands/**" \
  "$RT/repo/.mcp.json" "$RT/repo/.claude/hooks/**" "$RT/repo/.claude/CLAUDE.md" "$RT/repo/.claude/rules/**" \
  "$RW1/.claude/settings.json" "$RW1/.claude/settings.local.json" "$RHC/settings.json" "$RH/.claude.json" "$RHC/CLAUDE.md" \
  "$RHC/plugins/**" "$RHC/skills/**" "$RHC/agents/**" "$RHC/commands/**" "$RHC/hooks/**" "$RHC/rules/**"; do
  rules $T/state/settings/w1.json deny | grep -qxF "Edit(/$p)" || missing="$missing $p"
done
[ -z "$missing" ] && ok "w1.json: Edit deny on every protected path" || { bad "protected paths missing:$missing"; rules $T/state/settings/w1.json deny; }
# The repository's auto-memory folder, which the owner's own sessions load (#108): denied for every
# seat with auto memory off (em, w1), in both spellings of the repo path ($T is under a symlink, and
# Claude Code names the folder after the path), and not for w2 (auto_memory: true).
MEMA="$RHC/projects/$(enc "$T/repo")/memory/**"; MEMB="$RHC/projects/$(enc "$RT/repo")/memory/**"
missing=""; for r in em w1; do for p in "$MEMA" "$MEMB"; do rules $T/state/settings/$r.json deny | grep -qxF "Edit(/$p)" || missing="$missing $r:$p"; done; done
[ -z "$missing" ] && [ "$MEMA" != "$MEMB" ] && ok "auto-memory folder: Edit deny for em and w1 (auto memory off), both spellings of the repo path" || { bad "auto-memory folder deny missing:$missing"; rules $T/state/settings/w1.json deny | grep memory; }
w2mem=$(TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml settings w2 | grep -c '/memory/\*\*')
[ "$w2mem" = 0 ] && ok "auto-memory folder: no deny for w2 (auto_memory: true)" || bad "auto-memory folder denied for w2 ($w2mem rules)"
rules $T/state/settings/w1.json deny | grep -qE "state/notes/\*\*|state/notes/w1\.md|Edit\(//$RT/state/\*\*\)|Edit\(//$RHC/\*\*\)" && bad "protected paths are too wide (all notes or the seat's own, whole state dir or whole ~/.claude)" || ok "protected paths leave the seat's own note and the rest of ~/.claude writable"
# Claude Code puts the worktrees it makes (--worktree, subagents with isolation: worktree) under
# <repo>/.claude/worktrees/, so no deny may cover that folder.
# $T is the path as configured; on macOS it runs through the /var symlink, so its real path ($RT)
# differs. Both spellings of a protected path are denied.
missing=""
for p in "$T/repo/.mcp.json" "$T/repo/.claude/settings.json" "$T/state/settings/**" "$T/team.yaml" "$T/bin/wrap"; do
  rules $T/state/settings/w1.json deny | grep -qxF "Edit(/$p)" || missing="$missing $p"
done
[ "$T" != "$RT" ] && [ -z "$missing" ] && ok "a protected path reached through a symlink is denied by both spellings" || { bad "configured spellings missing:$missing"; }
rules $T/state/settings/w1.json deny | grep -E "^Edit\(/($RT|$T)/repo/\.claude/(\*\*|worktrees)" && bad "a deny covers <repo>/.claude/worktrees" || ok "no deny covers <repo>/.claude/worktrees (Claude Code's own worktrees stay editable)"
rules $T/state/settings/em.json deny | grep -qxF "Edit(/$RT/proj/.claude/settings.json)" && ok "em.json: protects em's own workdir settings" || bad "em.json: workdir settings deny"
esc=$(TEAM_STATE_DIR='/tmp/sf-e2e-no[such]*dir' ruby $SRC/lib/team_config.rb $T/team.yaml settings em | ruby -rjson -e 'puts JSON.parse(STDIN.read)["permissions"]["deny"]' | grep "sf-e2e-no")
echo "$esc" | grep -qxF 'Edit(//private/tmp/sf-e2e-no\[such\]\*dir/settings/**)' && echo "$esc" | grep -qxF 'Edit(//tmp/sf-e2e-no\[such\]\*dir/settings/**)' && ok "glob characters in a protected path are escaped" || { bad "glob escaping"; echo "$esc"; }
base_rules='Bash(git push * main)
Bash(git push * main *)
Bash(git push *:main)
Bash(git push *:main *)
Bash(git push *+main)
Bash(git push *+main *)
Bash(git push */main)
Bash(git push */main *)'
[ "$(rules $T/state/settings/em.json ask | grep '^Bash(git push ')" = "$base_rules" ] && ok "ask on any push to the base branch (main, from origin/main): the 8 patterns" || { bad "base-branch ask"; rules $T/state/settings/em.json ask; }
chk=$($S -c $T/team.yaml check 2>&1)
# check names the factory checkout the team runs from and its commit (#189): a team pinned to a
# release runs from its own checkout. Not read from $SRC, which may be an export with no .git (tl on
# #191): a throwaway git checkout of copied files, with a lightweight tag (plain describe skips one),
# then a change to a tracked file (-dirty). The team file in teams/ is untracked, so not dirty.
mkdir -p $T/ginst/teams && cp -R $SRC/factory.sh $SRC/lib $SRC/roles $SRC/plugin $T/ginst/ && echo tracked > $T/ginst/VERSION
gq() { git -C $T/ginst -c user.name=e2e -c user.email=e2e@example.invalid -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
gq init -q && gq add -A && gq commit -q -m release && gq tag v9.8.7 && cp $T/team.yaml $T/ginst/teams/team.yaml
gl=$($T/ginst/factory.sh -c $T/ginst/teams/team.yaml check 2>&1 | grep "^install ")
echo changed >> $T/ginst/VERSION
gd=$($T/ginst/factory.sh -c $T/ginst/teams/team.yaml check 2>&1 | grep "^install ")
[ "$gl" = "install   : $T/ginst at v9.8.7" ] && [ "$gd" = "install   : $T/ginst at v9.8.7-dirty" ] \
  && ok "check: the install line names the factory checkout and its tag (lightweight), with -dirty after a change" || { bad "check: install line in a git checkout"; echo "clean: $gl"; echo "dirty: $gd"; }
mkdir -p $T/linst/teams; for p in factory.sh lib roles plugin; do ln -s $SRC/$p $T/linst/$p; done; cp $T/team.yaml $T/linst/teams/team.yaml
$T/linst/factory.sh -c $T/linst/teams/team.yaml check 2>&1 | grep -qxF "install   : $T/linst (not a git checkout)" && ok "check: an install outside any git checkout says so" || { bad "check: install line outside git"; $T/linst/factory.sh -c $T/linst/teams/team.yaml check 2>&1 | grep -E "^(install|error)"; }
echo "$chk" | grep -qxF "bootstrap : $T/bin/boot (run in each new worktree before its seat starts)" && echo "$chk" | grep -qxF "copy      : .env.local, conf/dev.json, missing.txt (from the main checkout into each new worktree)" && ok "check: bootstrap and copy lines" || { bad "check: bootstrap and copy lines"; echo "$chk" | grep -E "^(bootstrap|copy) "; }
echo "$chk" | grep -qE "^em +Manager .* bypassPermissions " && echo "$chk" | grep -qE "^w1 +Worker One .* default " && ok "check: MODE column per role" || { bad "check MODE column"; echo "$chk"; }
echo "$chk" | grep -qE "^w1 +Worker One +tt-w1 +sonnet +low " && echo "$chk" | grep -qE "^em +Manager +tt-em +\(inherit\) +\(inherit\) " \
  && ok "check: MODEL and EFFORT columns per role (a role's own, or inherit)" || { bad "check MODEL/EFFORT columns"; echo "$chk"; }
echo "$chk" | grep -qF "warning: seat-to-seat messages will be held. Prompting for permissions: w1 (default). Bypassing them: em (bypassPermissions), w2 (bypassPermissions)." && ok "check: a team whose seats fall into both message classes is warned, naming each" || { bad "check: held-message warning on the mixed test team"; echo "$chk" | grep -A2 "^warning"; }
sect() { echo "$chk" | sed -n "/^\[$1\]/,/^\[/p"; }
sect w1 | grep -qF "deny : Read(//**/.env), Bash(touch tt-deny*), Bash(gh pr merge *)" && ok "check: w1's merged deny list" || { bad "check w1 deny"; sect w1; }
sect em | grep -qF "allow rules have no effect in bypassPermissions" && ! sect w1 | grep -qF "no effect in bypassPermissions" && ok "check: bypass note on em only" || { bad "check bypass note"; sect em; }
# Claude Code's auto-updater reinstalls its package under running seats, and macOS then loses
# track of the seat's process (#50): every seat starts with it off, in the launch script and in its
# settings, and nothing else in the tmux server gets the variable.
grep -qx "em DISABLE_AUTOUPDATER=1" $T/env.log && grep -qx "w1 DISABLE_AUTOUPDATER=1" $T/env.log && ok "seats run with DISABLE_AUTOUPDATER=1 in their environment" || { bad "seat environment"; cat $T/env.log; }
noenv=""; for r in em w1; do ruby -rjson -e 'exit(JSON.parse(File.read(ARGV[0])).dig("env", "DISABLE_AUTOUPDATER") == "1" ? 0 : 1)' $T/state/settings/$r.json || noenv="$noenv $r"; done
[ -z "$noenv" ] && ok "every seat's settings set env DISABLE_AUTOUPDATER=1" || bad "settings without env DISABLE_AUTOUPDATER=1:$noenv"
! tmux show-environment -g DISABLE_AUTOUPDATER >/dev/null 2>&1 && ! tmux show-environment -t '=tt-em:' DISABLE_AUTOUPDATER >/dev/null 2>&1 && ok "the variable is not in the tmux server's or the session's environment (other programs there are unaffected)" || bad "DISABLE_AUTOUPDATER leaked into tmux's environment"
# Auto memory is shared by every worktree of the repo and loads into every session there (#71): it
# is off in every seat unless the team file turns it on (w2 has auto_memory: true).
grep -qx "em CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" $T/env.log && grep -qx "w1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" $T/env.log && ok "auto memory: em and w1 run with CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" || { bad "auto memory: seat environment"; grep AUTO_MEMORY $T/env.log; }
[ "$(am < $T/state/settings/em.json)" = 'false "1"' ] && [ "$(am < $T/state/settings/w1.json)" = 'false "1"' ] && ok "auto memory: off by default in the generated settings (autoMemoryEnabled false, env CLAUDE_CODE_DISABLE_AUTO_MEMORY=1)" || { bad "auto memory: default settings"; am < $T/state/settings/em.json; am < $T/state/settings/w1.json; }
$S -c $T/team.yaml check >/dev/null 2>&1 && [ "$(TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml settings w2 | am)" = 'nil nil' ] && ok "auto memory: auto_memory: true leaves both unset, so Claude Code's own settings decide" || { bad "auto memory: w2 settings"; TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml settings w2; }
grep -qx "export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" $T/state/launch/em.sh && grep -qx "export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" $T/state/launch/w1.sh && ok "auto memory: the launch script exports the variable" || { bad "auto memory: launch scripts"; grep -H AUTO_MEMORY $T/state/launch/*.sh; }
echo "$chk" | grep -qE "^em .* off +- " && echo "$chk" | grep -qE "^w1 .* off +on-stop " && echo "$chk" | grep -qE "^w2 .* \(inherit\) +- " && ok "check: MEMORY column (off for em and w1, (inherit) for w2)" || { bad "check MEMORY column"; echo "$chk" | grep -E "^(ROLE|em|w1|w2) "; }
# Seats run the team's own copy of claude, made by up, never the shared install (#50).
CP=$T/state/bin/claude-9.9.9/claude
[ -x $CP ] && grep -qx "em $CP" $T/bin.log && grep -qx "w1 $CP" $T/bin.log && ok "seats run the team's copy of claude ($CP), made by up" || { bad "seats' claude copy"; cat $T/bin.log; ls -la $T/state/bin 2>&1; }
! grep -qF -e "$T/bin/claude" -e "$RT/bin/claude" $T/state/launch/em.sh $T/state/launch/w1.sh && grep -qF "$CP" $T/state/launch/em.sh && ok "the launch script names the copy, never the shared install" || { bad "launch script claude path"; grep claude_bin $T/state/launch/em.sh; }
echo "$chk" | grep -qF "claude    : $RT/bin/claude, version 9.9.9" && echo "$chk" | grep -qF "$T/state/bin/claude-9.9.9 (clone): em w1" && ok "check: the shared claude, its version, and each copy with the seats running it" || { bad "check: claude lines"; echo "$chk" | grep -A3 "^claude"; }
# The shared install is replaced the way npm does it (a new file in its place): the seats keep theirs.
cc -o $T/bin/claude.new $T/c.c && mv $T/bin/claude.new $T/bin/claude
$S -c $T/team.yaml status | grep -E "^em " | grep -qF "$RT/state/bin/claude-9.9.9/claude" && ok "status: after the shared claude is replaced, em still runs its intact copy" || { bad "status after shared replace"; $S -c $T/team.yaml status; }
echo "$chk" | grep -qF "updates   : Claude Code's auto-updater is off in every seat (DISABLE_AUTOUPDATER=1)" && ok "check: says the auto-updater is off in seats" || bad "check: updater line"
echo "$chk" | grep -qF "add to" && ok "check: says the rules add to the user's and the repo's own settings" || bad "check: add-to note"
# The gate runs as a Stop hook for roles with gate_on_stop (w1) and for no other role.
hook=$(ruby -rjson -e 'j = JSON.parse(File.read(ARGV[0])); h = j.dig("hooks", "Stop", 0, "hooks", 0) || {}; puts [j["hooks"]["Stop"].size, h["type"], h["command"], *h["args"], h["timeout"], j["disableAllHooks"].inspect].join(" | ")' $T/state/settings/w1.json 2>&1)
[ "$hook" = "1 | command | $SRC/lib/stop_gate.sh | $T/state | w1 | $VOL/$ROOT/team-w1 | make check | 120 | 2 | 150 | false" ] && ok "w1.json: one Stop hook running stop_gate.sh with state, role, workdir, gate, timeout, max blocks; disableAllHooks false" || { bad "w1 Stop hook"; echo "$hook"; }
# w2 has not started yet at this point (its legacy worktree is refused above): ask the builder.
nostop() { ruby -rjson -e 'j = JSON.parse(STDIN.read); exit((j["hooks"] || {}).key?("Stop") ? 1 : 0)'; }
nostop < $T/state/settings/em.json && TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml settings w2 | nostop && ok "roles without gate_on_stop (em, w2) get no Stop hook" || bad "a role without gate_on_stop got a Stop hook"
# Every seat gets one SessionStart hook (#5), for every start source (no matcher: startup, resume,
# clear and compact), that shows it its progress note, branch and recent commits.
sshook() { ruby -rjson -e 'j = JSON.parse(STDIN.read); a = (j["hooks"] || {})["SessionStart"] || []; h = (a[0] || {}).fetch("hooks", [])[0] || {}
  puts [a.size, (a[0] || {}).key?("matcher"), h["type"], h["command"], *h["args"], h["timeout"], j["disableAllHooks"].inspect].join(" | ")' 2>&1; }
ss_em=$(sshook < $T/state/settings/em.json); ss_w1=$(sshook < $T/state/settings/w1.json); ss_w2=$(TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml settings w2 | sshook)
# disableAllHooks: false only for the gated seat (w1): the note is a convenience and does not
# override a user who switched every hook off; the gate is a control and does.
[ "$ss_em" = "1 | false | command | $SRC/lib/session_start.sh | $T/state | em | $T/proj | 10 | nil" ] \
  && [ "$ss_w1" = "1 | false | command | $SRC/lib/session_start.sh | $T/state | w1 | $VOL/$ROOT/team-w1 | 10 | false" ] \
  && [ "$ss_w2" = "1 | false | command | $SRC/lib/session_start.sh | $T/state | w2 | $VOL/$ROOT/team-w2 | 10 | nil" ] \
  && ok "every seat (em, w1, w2): one SessionStart hook running session_start.sh with state, role, workdir; disableAllHooks false only for gated w1" || { bad "SessionStart hook"; echo "$ss_em"; echo "$ss_w1"; echo "$ss_w2"; }
# Every seat logs its SendMessage traffic to messages.log (#39): a PostToolUse hook for a message that
# went out and a PostToolUseFailure hook for one that failed, both on SendMessage only, with the log,
# the sender's role and the roster's session-to-role map as arguments.
smhook() { ruby -rjson -e 'j = JSON.parse(STDIN.read); h = j["hooks"] || {}
  puts(%w[PostToolUse PostToolUseFailure].map { |e| a = h[e] || []; x = (a[0] || {}).fetch("hooks", [])[0] || {}
    [e, a.size, (a[0] || {})["matcher"], x["type"], x["command"], *x["args"], x["timeout"]].join(" | ") })' 2>&1; }
smwant() { for e in PostToolUse PostToolUseFailure; do echo "$e | 1 | SendMessage | command | $SRC/lib/log_message.sh | $T/state/messages.log | $1 | tt-em=em | tt-w1=w1 | tt-w2=w2 | 5"; done; }
sm_em=$(smhook < $T/state/settings/em.json); sm_w1=$(smhook < $T/state/settings/w1.json); sm_w2=$(TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml settings w2 | smhook)
[ "$sm_em" = "$(smwant em)" ] && [ "$sm_w1" = "$(smwant w1)" ] && [ "$sm_w2" = "$(smwant w2)" ] \
  && ok "every seat (em, w1, w2): SendMessage logging hooks on PostToolUse and PostToolUseFailure, with log, role and the session map" || { bad "SendMessage logging hooks"; echo "$sm_em"; echo "$sm_w1"; }
# The log holds every native message in full, private reports to the EM included (owner decision on
# #110): every seat but em has a Read deny on it, in both spellings. An accident guard only.
lr=""; w2deny=$(TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml settings w2 | ruby -rjson -e 'puts JSON.parse(STDIN.read)["permissions"]["deny"]')
for sp in "$RT" "$T"; do
  rules $T/state/settings/em.json deny | grep -qxF "Read(/$sp/state/messages.log)" && lr="$lr em-denied($sp)"
  rules $T/state/settings/w1.json deny | grep -qxF "Read(/$sp/state/messages.log)" || lr="$lr w1-not-denied($sp)"
  echo "$w2deny" | grep -qxF "Read(/$sp/state/messages.log)" || lr="$lr w2-not-denied($sp)"
done
[ -z "$lr" ] && ok "messages.log: Read denied to w1 and w2 (both spellings), readable by em" || { bad "messages.log read rules:$lr"; rules $T/state/settings/w1.json deny | grep messages; }
# check names the Read deny for the seats that have it, and keeps it out of the protected-path count.
# w1's team and role denies hold no Edit rule, so its protected paths are its Edit denies but the notes
# and the auto-memory folder (#112) and the triage folder (#138), which check names on their own.
nw1=$(sect w1 | sed -n 's/.*added: Edit deny on \([0-9]*\) protected paths.*/\1/p')
ew1=$(rules $T/state/settings/w1.json deny | grep '^Edit(' | grep -v -e '/state/notes/' -e '/memory/\*\*' -e '/state/triage/\*\*' | wc -l | tr -d ' ')
sect w1 | grep -F "added: " | grep -qF ", Read deny on the message log" && ! sect em | grep -qF "Read deny on the message log" && [ -n "$nw1" ] && [ "$nw1" = "$ew1" ] \
  && ok "check: w1's added line names the message log Read deny (not counted among its $nw1 protected paths), em's does not" || { bad "check: message log Read deny line (counted $nw1, Edit denies $ew1)"; sect w1; sect em; }
# A seat may write its own note without a prompt (it is outside its working directory), and only its
# own: every other seat's note is denied, as exact paths in both spellings, since a note is put into
# its seat's context at each start.
na=""; for f in em w1; do for o in em w1 w2; do for sp in "$RT" "$T"; do
  if [ $f = $o ]; then rules $T/state/settings/$f.json allow | grep -qxF "Edit(/$sp/state/notes/$o.md)" || na="$na $f-allows-$o($sp)"
    rules $T/state/settings/$f.json deny | grep -qxF "Edit(/$sp/state/notes/$o.md)" && na="$na $f-denies-own($sp)"
  else rules $T/state/settings/$f.json deny | grep -qxF "Edit(/$sp/state/notes/$o.md)" || na="$na $f-denies-$o($sp)"
    rules $T/state/settings/$f.json allow | grep -qF "notes/$o.md" && na="$na $f-allows-other-$o"; fi
done; done; done
rules $T/state/settings/w1.json deny | grep -qF "state/notes/**" && na="$na notes/**-denied"
[ -z "$na" ] && ok "em.json, w1.json: Edit allowed on the seat's own note, denied on every other seat's (both spellings, exact paths)" || { bad "note rules:$na"; rules $T/state/settings/w1.json deny | grep notes; rules $T/state/settings/w1.json allow; }
sect em | grep -qF "Edit deny on the repository's auto-memory folder" && sect w1 | grep -qF "Edit deny on the repository's auto-memory folder" && ! sect w2 | grep -qF "auto-memory folder" && ok "check: names the auto-memory folder deny for em and w1, not for w2" || { bad "check: auto-memory folder"; sect w2; }
sect em | grep -qF "added: Edit deny on" && sect em | grep -qF ", Edit allow on its own progress note and deny on the other seats'" && ! sect em | grep -E "^ +(allow|deny) *:" | grep -qF notes \
  && ok "check: the note allow is listed as added by the launcher, not among the team's allow rules" || { bad "check: note allow line"; sect em; }
echo "--- security-triage record folder (#138)"
# Only the role with id sec writes triage records, in <state>/triage/: it may edit and read the
# folder (outside its working directory, so it would prompt otherwise), em may read it, and every
# other seat is denied both, in both spellings. This team is the test team plus a sec role, and w2
# lists the security-triage skill, which check warns about.
sed 's/^  w2: { title: Worker Two, /  w2: { title: Worker Two, skills: ["factory:security-triage"], /' $T/team.yaml > $T/sec.yaml
echo '  sec: { title: Security, workdir: { type: worktree }, prompt_text: "sec prompt" }' >> $T/sec.yaml
# tset <team file> <role> <list>: that list of the role's generated settings, one rule a line.
tset() { TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb "$1" settings "$2" | ruby -rjson -e 'puts((JSON.parse(STDIN.read)["permissions"] || {})[ARGV[0]] || [])' "$3"; }
tr=""
for r in sec em w1 w2; do
  al=$(tset $T/sec.yaml $r allow); dn=$(tset $T/sec.yaml $r deny)
  for sp in "$RT" "$T"; do
    E="Edit(/$sp/state/triage/**)"; R="Read(/$sp/state/triage/**)"
    has() { printf '%s\n' "$1" | grep -qxF "$2"; }
    case $r in
      sec) has "$al" "$E" && has "$al" "$R" && ! has "$dn" "$E" && ! has "$dn" "$R" || tr="$tr sec($sp)" ;;
      em) has "$al" "$R" && ! has "$al" "$E" && has "$dn" "$E" && ! has "$dn" "$R" || tr="$tr em($sp)" ;;
      *) has "$dn" "$E" && has "$dn" "$R" && ! has "$al" "$E" && ! has "$al" "$R" || tr="$tr $r($sp)" ;;
    esac
  done
done
[ -z "$tr" ] && [ "$T" != "$RT" ] && ok "triage folder: Edit and Read allowed to sec, Read to em (Edit denied), both denied to w1 and w2, both spellings" || { bad "triage folder rules:$tr"; tset $T/sec.yaml sec allow | grep triage; tset $T/sec.yaml w1 deny | grep triage; }
# No deny of sec's (team, role or launcher) covers a file in the folder, nor any of em's Read denies:
# a deny wins over an allow, so one would make the allow do nothing. Each Edit or Read path rule is
# matched as a glob against a record's path, * crossing folders (wider than Claude Code's matching,
# so it errs towards finding a shadow).
shadow() { ruby -e 'tool = ARGV.shift; path = ARGV.shift
  STDIN.read.split("\n").each { |r| m = r.match(/\A(Edit|Read)\(\/(.*)\)\z/) or next
    next if tool == "Read" && m[1] != "Read"
    puts r if File.fnmatch(m[2], path, File::FNM_DOTMATCH) }' "$@"; }
sh=""; for sp in "$RT" "$T"; do
  sh="$sh$(tset $T/sec.yaml sec deny | shadow Any "$sp/state/triage/pr-1.md")$(tset $T/sec.yaml em deny | shadow Read "$sp/state/triage/pr-1.md")"
done
probe=$(printf '%s\n' "Edit(/$RT/state/**)" "Read(//**/.env)" | shadow Any "$RT/state/triage/pr-1.md")
[ -z "$sh" ] && [ "$probe" = "Edit(/$RT/state/**)" ] && ok "triage folder: no deny shadows sec's allows or em's Read allow (the matcher finds a shadow when there is one)" || { bad "triage folder: shadowed allow"; echo "$sh"; echo "probe: $probe"; }
# A team with no sec role has no record folder, and no seat may write one.
nt=""; for r in em w1 w2; do
  al=$(tset $T/team.yaml $r allow); dn=$(tset $T/team.yaml $r deny)
  printf '%s\n' "$al" | grep -qF "Edit(/$RT/state/triage/**)" && nt="$nt $r-edit-allowed"
  printf '%s\n' "$dn" | grep -qxF "Edit(/$RT/state/triage/**)" || nt="$nt $r-edit-not-denied"
  [ $r = em ] || printf '%s\n' "$dn" | grep -qxF "Read(/$RT/state/triage/**)" || nt="$nt $r-read-not-denied"
done
[ -z "$nt" ] && [ -z "$(TEAM_STATE_DIR=$T/state ruby $SRC/lib/team_config.rb $T/team.yaml get state.triage_dir)" ] && [ ! -e $T/state/triage ] \
  && ok "triage folder: a team with no sec role gets none (up made none), and every seat is denied writing there" || { bad "triage folder without a sec role:$nt"; ls -la $T/state; }
# The folder is glob-escaped and the ** after it is not.
tesc=$(TEAM_STATE_DIR='/tmp/sf-e2e-no[such]*dir' ruby $SRC/lib/team_config.rb $T/sec.yaml settings sec | ruby -rjson -e 'puts JSON.parse(STDIN.read)["permissions"]["allow"]' | grep triage)
printf '%s\n' "$tesc" | grep -qxF 'Edit(//tmp/sf-e2e-no\[such\]\*dir/triage/**)' && printf '%s\n' "$tesc" | grep -qxF 'Read(//private/tmp/sf-e2e-no\[such\]\*dir/triage/**)' \
  && ok "triage folder: glob characters in the state path are escaped, the trailing ** is not" || { bad "triage folder glob escaping"; echo "$tesc"; }
# The skill keeps sec on the tools its allows cover: a Bash write or read of a record would prompt
# outside bypass, which is what the folder's rules exist to prevent (#138, as #90 for the notes).
tr '\n' ' ' < $SRC/plugin/skills/security-triage/SKILL.md | tr -s ' ' | grep -qF "Write and update the record with the Write or Edit tool, and read it with the Read tool, not Bash" \
  && ok "the security-triage skill says to write and read the record with the file tools, not Bash" || bad "the security-triage skill does not say which tools write and read the record"
# check names the rules on each seat's added line, and warns about a role other than sec that lists the skill.
schk=$($S -c $T/sec.yaml check 2>&1); ssect() { echo "$schk" | sed -n "/^\[$1\]/,/^\[/p"; }
ssect sec | grep -F "added: " | grep -qF ", Edit and Read allow on the triage record folder" && ssect em | grep -F "added: " | grep -qF ", Read allow and Edit deny on the triage record folder" \
  && ssect w1 | grep -F "added: " | grep -qF ", Edit and Read deny on the triage record folder" \
  && echo "$schk" | grep -qxF "warning: w2 lists factory:security-triage, but only a role with id sec may write triage records ($T/state/triage/): every other seat may not write there." \
  && ! echo "$schk" | grep -q "warning: sec lists factory:security-triage" \
  && ok "check: the triage folder rules on each seat's added line, and a warning for w2, which lists the skill and is not sec" || { bad "check: triage folder"; ssect sec; ssect em; echo "$schk" | grep warning; }
echo "--- other teams' state folders (#197)"
# Two teams on one factory checkout, their state folders side by side in one state root ($X): each
# team's seats get Read denies on the other's triage records, log and notes and an Edit deny on all
# of it, in both spellings ($T and its real path), and none of these on their own. A team's state
# folder is one holding settings/, launch/ and prompts/, which up makes. In the root, a link is
# skipped and named (one leads to our own state), and a folder without team state is passed over
# quietly. A folder elsewhere is listed under other_teams, where an observer role (w1) may read its
# log and notes, never its triage records. em, which reads its own team's log, is denied the other's.
X=$T/xroot
for d in $X/xa $X/xb $T/far/elsewhere $T/far/xc; do mkdir -p $d/settings $d/launch $d/prompts; done
mkdir -p $X/junk/notes && ln -s $X/xa $X/xlink && ln -s $T/far/elsewhere $X/xlink2
sed 's/^team: tt$/team: xa/' $T/sec.yaml > $T/xa.yaml && printf 'other_teams:\n  - { state: %s/far/xc, observers: [w1] }\n' $T >> $T/xa.yaml
sed 's/^team: tt$/team: xb/' $T/sec.yaml > $T/xb.yaml
xset() { TEAM_STATE_DIR=$X/$1 ruby $SRC/lib/team_config.rb $T/$1.yaml settings $2 | ruby -rjson -e 'puts((JSON.parse(STDIN.read)["permissions"] || {})[ARGV[0]] || [])' "$3"; }
xhas() { printf '%s\n' "$1" | grep -qxF "$2"; }
xr=""
for r in em sec w1 w2; do
  dn=$(xset xa $r deny); al=$(xset xa $r allow)
  for sp in "$T" "$RT"; do
    B=$sp/xroot/xb; C=$sp/far/xc
    for rule in "Read(/$B/triage/**)" "Read(/$B/messages.log)" "Read(/$B/notes/**)" "Edit(/$B/**)" "Read(/$C/triage/**)" "Edit(/$C/**)"; do xhas "$dn" "$rule" || xr="$xr $r-lacks:$rule"; done
    for rule in "Read(/$C/messages.log)" "Read(/$C/notes/**)"; do
      if [ $r = w1 ]; then xhas "$dn" "$rule" && xr="$xr w1-observer-denied:$rule"; else xhas "$dn" "$rule" || xr="$xr $r-lacks:$rule"; fi
    done
    for rule in "Edit(/$sp/xroot/xa/**)" "Read(/$sp/xroot/xa/notes/**)"; do xhas "$dn" "$rule" && xr="$xr $r-denied-own:$rule"; done
    printf '%s\n' "$dn" "$al" | grep -qE "/xroot/(xlink|xlink2|junk)[/)]" && xr="$xr $r-names-a-skipped-folder($sp)"
  done
  xhas "$al" "Edit(/$T/xroot/xa/triage/**)" || [ $r != sec ] || xr="$xr sec-lost-own-triage"
done
for r in em sec; do dn=$(xset xb $r deny)
  for sp in "$T" "$RT"; do xhas "$dn" "Read(/$sp/xroot/xa/triage/**)" && xhas "$dn" "Read(/$sp/xroot/xa/messages.log)" && xhas "$dn" "Edit(/$sp/xroot/xa/**)" || xr="$xr xb-$r-lacks-xa($sp)"; done
done
[ -z "$xr" ] && [ "$T" != "$RT" ] && ok "other teams: each team's seats are denied the other's triage, log and notes (Read) and all of it (Edit), both spellings; an observer may read the listed team's log and notes; nothing for links, folders without state, or our own state" || bad "other teams' rules:$xr"
xchk=$(TEAM_STATE_DIR=$X/xa $S -c $T/xa.yaml check 2>&1); xsect() { echo "$xchk" | sed -n "/^\[$1\]/,/^\[/p"; }
echo "$xchk" | grep -qxF "other teams: $X/xb (found), $T/far/xc (listed; observers: w1)" \
  && echo "$xchk" | grep -qxF "skipped   : $X/xlink (a symlink to this team's own state folder, or to a folder holding it)" \
  && echo "$xchk" | grep -qxF "skipped   : $X/xlink2 (a symlink: list it under other_teams if it is another team's state folder)" \
  && ! echo "$xchk" | grep -qF "$X/junk" \
  && xsect em | grep -F "added: " | grep -qF ", Read and Edit deny on 2 other teams' state folders" \
  && xsect w1 | grep -F "added: " | grep -qF ", Read and Edit deny on 2 other teams' state folders (observer of $T/far/xc: may read its log and notes)" \
  && ok "check: lists the other teams found and listed, the links it skipped and why (not a folder without team state), and the denies on each seat's added line" || { bad "check: other teams"; echo "$xchk" | grep -E "^(other teams|skipped)"; xsect w1 | grep added; }
# A state root inside the team's own repository (a team working on software-factory keeps .state/ in
# its checkout, tl on #200): a team found there, or listed there before it exists, is not "inside the
# repository", so it still gets its denies.
mkdir -p $T/repo/.state/me $T/repo/.state/other/settings $T/repo/.state/other/launch $T/repo/.state/other/prompts
printf 'other_teams:\n  - { state: %s/repo/.state/later }\n' $T | cat $T/sec.yaml - > $T/inrepo.yaml
idn=$(TEAM_STATE_DIR=$T/repo/.state/me ruby $SRC/lib/team_config.rb $T/inrepo.yaml settings w1 2>&1 | ruby -rjson -e 'puts JSON.parse(STDIN.read)["permissions"]["deny"]' 2>&1)
ichk=$(TEAM_STATE_DIR=$T/repo/.state/me $S -c $T/inrepo.yaml check 2>&1)
printf '%s\n' "$idn" | grep -qxF "Edit(/$T/repo/.state/other/**)" && printf '%s\n' "$idn" | grep -qxF "Read(/$T/repo/.state/other/triage/**)" && printf '%s\n' "$idn" | grep -qxF "Edit(/$T/repo/.state/later/**)" \
  && echo "$ichk" | grep -qxF "other teams: $T/repo/.state/other (found), $T/repo/.state/later (listed; not found yet)" \
  && ok "other teams: a state root inside the repository still finds and lists the teams there" || { bad "other teams: state root inside the repository"; echo "$idn" | grep -F ".state/" | head -4; echo "$ichk" | grep -E "^(other teams|skipped|error)"; }
rm -r "$T/repo/.state"
# A state root that is the repository itself exempts nothing (sec on #200): a folder there is inside the repository.
mkdir -p $T/repo/me
rout=$(TEAM_STATE_DIR=$T/repo/me $S -c $T/inrepo.yaml check 2>&1); rc=$?
[ $rc != 0 ] && echo "$rout" | grep -qF "other_teams: $T/repo/.state/later is, holds or sits inside this team's repository (repo.path)" \
  && ok "other teams: a state root that is the repository itself exempts nothing" || { bad "other teams: state root = repository (rc=$rc)"; echo "$rout" | tail -2; }
rmdir "$T/repo/me"
# A team alone in its state root gets no rule of these, and a link or a folder without state beside it adds none.
mkdir -p $T/aroot/solo/settings $T/aroot/solo/launch $T/aroot/solo/prompts; s0=$(TEAM_STATE_DIR=$T/aroot/solo ruby $SRC/lib/team_config.rb $T/sec.yaml settings w1)
mkdir -p $T/aroot/stuff/notes && ln -s $T/aroot/solo $T/aroot/solink; s1=$(TEAM_STATE_DIR=$T/aroot/solo ruby $SRC/lib/team_config.rb $T/sec.yaml settings w1)
[ -n "$s0" ] && [ "$s0" = "$s1" ] && ! echo "$s0" | grep -qE "/aroot/(stuff|solink)" && ok "other teams: a team alone gets none of these rules, and a link or a folder without state beside it adds none" || { bad "other teams: a team alone"; diff <(echo "$s0") <(echo "$s1"); }
reject "other_teams: this team's own state folder" "other_teams: $T/state is this team's own state folder, holds it or sits inside it" "" "other_teams: [{ state: $T/state }]"
reject "other_teams: a folder that holds this team's state (/)" "other_teams: / is this team's own state folder, holds it or sits inside it" "" "other_teams: [{ state: / }]"
reject "other_teams: a folder inside this team's state" "other_teams: $T/state/sub is this team's own state folder, holds it or sits inside it" "" "other_teams: [{ state: $T/state/sub }]"
reject "other_teams: an observer that is not a role" "other_teams: observer nope of $T/far/xc is not a role of this team" "" "other_teams: [{ state: $T/far/xc, observers: [nope] }]"
reject "other_teams: an unknown key" "unknown key(s) under 'other_teams' entry 1: bogus (allowed: state, observers)" "" "other_teams: [{ state: $T/far/xc, bogus: 1 }]"
reject "other_teams: not a list" "other_teams must be a list of { state, observers } entries" "" "other_teams: $T/far/xc"
# A miscased spelling of this team's own state folder is refused on a case-insensitive disk (sec on #200).
if [ -d "$(dirname $T/state)/STATE" ]; then
  reject "other_teams: this team's own state folder, miscased" "other_teams: $T/STATE is this team's own state folder, holds it or sits inside it" "" "other_teams: [{ state: $T/STATE }]"
else ok "other_teams: miscased own state folder (case-sensitive disk: the spellings are different folders)"; fi
# A listed folder that exists must be a team's state folder (tl on #200): home, the repo or a state
# root one level too high would deny this team's own work or protect nothing. A missing one is noted.
reject "other_teams: the home folder" "other_teams: $HOME is or holds the home folder" "" "other_teams: [{ state: \"~\" }]"
reject "other_teams: a folder holding the home folder" "other_teams: $(dirname $HOME) is or holds the home folder" "" "other_teams: [{ state: $(dirname $HOME) }]"
reject "other_teams: the repo" "other_teams: $T/repo is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo }]"
reject "other_teams: a state root one level too high" "other_teams: $X is not a team's state folder" "" "other_teams: [{ state: $X }]"
# Nor, existing or not, this team's own work: a future worktree would get an Edit deny once up made it (qa on #200).
reject "other_teams: this team's storage root" "other_teams: $VOL/$ROOT is, holds or sits inside this team's worktree folder" "" "other_teams: [{ state: $VOL/$ROOT }]"
reject "other_teams: a future worktree of this team" "other_teams: $VOL/$ROOT/team-zz is, holds or sits inside this team's worktree folder" "" "other_teams: [{ state: $VOL/$ROOT/team-zz }]"
reject "other_teams: a folder not yet made in the repo" "other_teams: $T/repo/later/st is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo/later/st }]"
reject "other_teams: a folder not yet made in a seat's working directory" "other_teams: $T/proj/later/st is, holds or sits inside seat em's working directory" "" "other_teams: [{ state: $T/proj/later/st }]"
mk "" "other_teams: [{ state: $T/nowhere/st, observers: [em] }]"; nchk=$($S -c $T/v.yaml check 2>&1); rc=$?
[ $rc = 0 ] && echo "$nchk" | grep -qF "other teams: $T/nowhere/st (listed; not found yet; observers: em)" && ok "other_teams: a folder that does not exist yet is accepted, and check says so" || { bad "other_teams: a missing folder (rc=$rc)"; echo "$nchk" | grep -E "^(other teams|error)"; }
# An existing but empty folder (that team has not run up yet) is handled like a missing one (#204):
# it loads, check names it, and check, status and say keep working. Only a lone .DS_Store is
# ignored: any other entry makes it a folder that must hold team state (tl on #204).
mkdir -p $T/far/empty $T/far/dsonly $T/far/hidden && : > $T/far/dsonly/.DS_Store && : > $T/far/hidden/.keep
mk "" "other_teams: [{ state: $T/far/empty, observers: [em] }, { state: $T/far/dsonly }]"
echk=$($S -c $T/v.yaml check 2>&1); rc=$?; est=$($S -c $T/v.yaml status 2>&1); erc=$?; esay=$($S -c $T/v.yaml say em hello 2>&1)
edn=$(ruby $SRC/lib/team_config.rb $T/v.yaml settings em 2>&1 | ruby -rjson -e 'puts JSON.parse(STDIN.read)["permissions"]["deny"]' 2>&1)
[ $rc = 0 ] && [ $erc = 0 ] && echo "$echk" | grep -qF "other teams: $T/far/empty (listed; empty, not a team's state yet; observers: em), $T/far/dsonly (listed; empty, not a team's state yet)" \
  && ! printf '%s\n' "$est" "$esay" | grep -qF "other_teams:" && printf '%s\n' "$edn" | grep -qxF "Edit(/$T/far/empty/**)" && printf '%s\n' "$edn" | grep -qxF "Read(/$T/far/dsonly/messages.log)" \
  && ok "other_teams: an empty folder (or one with only .DS_Store) is accepted like a missing one; check names it, and status and say still load" || { bad "other_teams: an empty folder (rc=$rc status=$erc)"; printf '%s\n' "$echk" "$est" "$esay" | grep -E "^(other teams|error)|other_teams:" | head -4; }
reject "other_teams: a folder holding only a hidden file other than .DS_Store" "other_teams: $T/far/hidden is not a team's state folder" "" "other_teams: [{ state: $T/far/hidden }]"
# An empty folder inside this team's own work is still refused, as a missing one is (tl on #204).
mkdir -p $T/repo/emptyst
reject "other_teams: an empty folder in the repo" "other_teams: $T/repo/emptyst is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo/emptyst }]"
rmdir $T/repo/emptyst
# A team pinned to a release whose repo.path is the factory checkout lists the checkout's
# <repo>/.state/<team> (#205): a real team state folder whose real parent is named .state is exempt
# from "sits inside" the repository, and gets every rule. Spelled through a link, the real path
# decides, and the parent's name is read from the disk. Without team state, without a real .state parent (a link named .state, or a source folder
# holding settings/, launch/ and prompts/), or the .state root itself, it is still refused.
mkdir -p $T/pinst/pin $T/repo/srclike/like $T/repo/realdir/t $T/repo/mc/.State/o
for d in $T/repo/.state/other $T/repo/srclike/like $T/repo/realdir/t $T/repo/mc/.State/o; do mkdir -p $d/settings $d/launch $d/prompts; done
ln -s $T/repo/.state $T/repo/alias && mkdir -p $T/repo/lnk && ln -s $T/repo/realdir $T/repo/lnk/.state
mk "" "other_teams: [{ state: $T/repo/.state/other }, { state: $T/repo/alias/other }]"
pchk=$(TEAM_STATE_DIR=$T/pinst/pin $S -c $T/v.yaml check 2>&1); rc=$?
pdn=$(TEAM_STATE_DIR=$T/pinst/pin ruby $SRC/lib/team_config.rb $T/v.yaml settings em 2>&1 | ruby -rjson -e 'puts JSON.parse(STDIN.read)["permissions"]["deny"]' 2>&1)
pr=""; for sp in "$T" "$RT"; do for rule in "Read(/$sp/repo/.state/other/triage/**)" "Read(/$sp/repo/.state/other/messages.log)" "Read(/$sp/repo/.state/other/notes/**)" "Edit(/$sp/repo/.state/other/**)"; do printf '%s\n' "$pdn" | grep -qxF "$rule" || pr="$pr lacks:$rule"; done; done
# Listed only through the link, the rules name that spelling as well as the real one (tl on #223).
mk "" "other_teams: [{ state: $T/repo/alias/other }]"
adn=$(TEAM_STATE_DIR=$T/pinst/pin ruby $SRC/lib/team_config.rb $T/v.yaml settings em 2>&1 | ruby -rjson -e 'puts JSON.parse(STDIN.read)["permissions"]["deny"]' 2>&1)
for rule in "Read(/$T/repo/alias/other/triage/**)" "Edit(/$T/repo/alias/other/**)" "Edit(/$RT/repo/.state/other/**)"; do printf '%s\n' "$adn" | grep -qxF "$rule" || pr="$pr link-lacks:$rule"; done
[ $rc = 0 ] && [ -z "$pr" ] && echo "$pchk" | grep -qF "other teams: $T/repo/.state/other (listed)" \
  && ok "other_teams: a pinned team whose repo is the factory lists <repo>/.state/<team>, with every rule, and through a link with that spelling's rules too" || { bad "other_teams: pinned factory layout (rc=$rc)$pr"; echo "$pchk" | grep -E "^(other teams|error)|other_teams:" | head -3; }
export TEAM_STATE_DIR=$T/pinst/pin
reject "other_teams: a missing folder in the repo's .state" "other_teams: $T/repo/.state/later is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo/.state/later }]"
reject "other_teams: a team-state-like source folder in the repo" "other_teams: $T/repo/srclike/like is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo/srclike/like }]"
reject "other_teams: a team folder under a link named .state" "other_teams: $T/repo/lnk/.state/t is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo/lnk/.state/t }]"
# The parent's name as stored on disk decides, not the entry's spelling: File.realpath keeps the typed
# case on a case-insensitive disk (tl on #223). On a case-sensitive disk .state/o does not exist, and
# a missing folder in the repo is refused the same way.
reject "other_teams: a team folder under .State on disk, listed as .state" "other_teams: $T/repo/mc/.state/o is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo/mc/.state/o }]"
reject "other_teams: the repo's .state root" "other_teams: $T/repo/.state is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo/.state }]"
reject "other_teams: the repo, for a pinned team" "other_teams: $T/repo is, holds or sits inside this team's repository (repo.path)" "" "other_teams: [{ state: $T/repo }]"
export TEAM_STATE_DIR=$T/state
rm $T/repo/alias $T/repo/lnk/.state && rmdir $T/repo/lnk && rm -r "$T/repo/.state" "$T/repo/srclike" "$T/repo/realdir" "$T/repo/mc" "$T/pinst"
# A state root that cannot be listed finds no other teams, without a stack trace, and check says so.
mkdir -p $T/uroot/u/settings $T/uroot/u/launch $T/uroot/u/prompts && chmod 300 $T/uroot
uchk=$(TEAM_STATE_DIR=$T/uroot/u $S -c $T/sec.yaml check 2>&1); rc=$?; chmod 700 $T/uroot
[ $rc = 0 ] && echo "$uchk" | grep -qxF "other teams: none" && echo "$uchk" | grep -qF "skipped   : $T/uroot (could not be listed (" && ! echo "$uchk" | grep -qF ".rb:" \
  && ok "other teams: a state root that cannot be listed finds none, and check says so" || { bad "other teams: unreadable state root (rc=$rc)"; echo "$uchk" | grep -E "^(other teams|skipped|error)|\.rb:" | head -5; }
# up makes the folder, owner-only, for a team with a sec role. up writes every seat's settings, so
# this runs in a state folder and session prefix of its own, leaving the test team's alone. Only sec
# is started; its session and worktree are removed afterwards.
sed 's/^  prefix: tt$/  prefix: ts/' $T/sec.yaml > $T/sec2.yaml
TEAM_STATE_DIR=$T/secstate $S -c $T/sec2.yaml up --no-view sec >/dev/null 2>&1
[ -d $T/secstate/triage ] && [ "$(stat -f %Lp $T/secstate/triage)" = 700 ] && ok "up makes the triage folder (mode 700) for a team with a sec role" || { bad "up: triage folder"; ls -la $T/secstate; }
# An existing folder with a looser mode gets 700 too, and its records are left alone. sec is still
# running, so this up only writes settings and folders and skips the seat.
chmod 755 $T/secstate/triage; echo record > $T/secstate/triage/pr-1.md
TEAM_STATE_DIR=$T/secstate $S -c $T/sec2.yaml up --no-view sec >/dev/null 2>&1
[ "$(stat -f %Lp $T/secstate/triage)" = 700 ] && [ "$(cat $T/secstate/triage/pr-1.md 2>/dev/null)" = record ] \
  && ok "up gives an existing triage folder mode 700 and leaves its records" || { bad "up: existing triage folder"; ls -la $T/secstate/triage; }
# up refuses a symlink, or anything else that is not a real folder, at every folder it makes or
# writes under the state folder, naming it: triage and notes (#148), the generated folders, the
# hooks' gate folder and the folder of the team's claude copy (#168). It makes, writes or chmods
# nothing through it and starts no seat: sec's session is stopped first, so an up that went on would
# start it. Each link points at a sentinel folder (mode 755, one file) whose mode, size, mtime and
# contents must come out unchanged. A folder that was not there (gate, which a gated seat's hook
# makes) is linked all the same, and the link is removed afterwards.
# snap <dir>: each entry's path, mode, size and mtime, then each file's checksum.
snap() { (cd "$1" && find . -exec stat -f '%N %Lp %z %m' {} + | sort && find . -type f -exec shasum {} + | sort); }
tmux kill-session -t '=ts-sec' 2>/dev/null
cpd=$(cd $T/secstate && ls -d bin/claude-*/ 2>/dev/null | head -1); cpd=${cpd%/}
[ -n "$cpd" ] || bad "no claude copy folder under $T/secstate/bin to test"
for sd in triage notes settings launch prompts bin setup gate $cpd; do
  sn=$T/sentinel-${sd//\//-}; mkdir -p $sn && echo keep > $sn/kept.md && chmod 755 $sn; before=$(snap $sn)
  had=; if [ -e $T/secstate/$sd ]; then had=1; mv $T/secstate/$sd $T/secstate/$sd.real; fi
  ln -s $sn $T/secstate/$sd
  sout=$(TEAM_STATE_DIR=$T/secstate $S -c $T/sec2.yaml up --no-view sec 2>&1); src=$?
  [ $src != 0 ] && echo "$sout" | grep -qxF "error: $T/secstate/$sd is not a real folder (a symlink, or not a folder): remove it, then run up again" \
    && [ "$(snap $sn)" = "$before" ] && [ -L $T/secstate/$sd ] && ! tmux has-session -t '=ts-sec' 2>/dev/null \
    && ok "up refuses a symlink at <state>/$sd, naming it, leaves the folder it points at unchanged and starts no seat" || { bad "up: symlink at <state>/$sd (rc=$src)"; echo "$sout" | tail -3; diff <(echo "$before") <(snap $sn); }
  tmux kill-session -t '=ts-sec' 2>/dev/null
  rm $T/secstate/$sd; [ -z "$had" ] || mv $T/secstate/$sd.real $T/secstate/$sd
done
# A plain file at the name is refused the same way, and left as it was.
for sd in notes settings; do
  mv $T/secstate/$sd $T/secstate/$sd.real && echo plain > $T/secstate/$sd
  sout=$(TEAM_STATE_DIR=$T/secstate $S -c $T/sec2.yaml up --no-view sec 2>&1); src=$?
  [ $src != 0 ] && echo "$sout" | grep -qxF "error: $T/secstate/$sd is not a real folder (a symlink, or not a folder): remove it, then run up again" && [ "$(cat $T/secstate/$sd)" = plain ] \
    && ! tmux has-session -t '=ts-sec' 2>/dev/null && ok "up refuses a plain file at <state>/$sd, naming it, and starts no seat" || { bad "up: plain file at <state>/$sd (rc=$src)"; echo "$sout" | tail -3; }
  tmux kill-session -t '=ts-sec' 2>/dev/null
  rm $T/secstate/$sd && mv $T/secstate/$sd.real $T/secstate/$sd
done
tmux kill-session -t '=ts-sec' 2>/dev/null; git -C $T/repo worktree remove --force $VOL/$ROOT/team-sec 2>/dev/null
# A user who switched every hook off keeps that choice in seats without a gate, which then get no
# note: check says which. Throwaway config folders, so the owner's own settings play no part.
mkdir -p $T/cfgoff $T/cfgon && echo '{"disableAllHooks": true}' > $T/cfgoff/settings.json && echo '{}' > $T/cfgon/settings.json
hk=$(CLAUDE_CONFIG_DIR=$T/cfgoff $S -c $T/team.yaml check 2>&1 | grep "^hooks ")
[ "$hk" = "hooks     : disableAllHooks is true in $T/cfgoff/settings.json, so em, w2 get no session-start note and no SendMessage logging (a gated seat turns hooks back on for its gate)" ] \
  && ! CLAUDE_CONFIG_DIR=$T/cfgon $S -c $T/team.yaml check 2>&1 | grep -q "^hooks " && ! CLAUDE_CONFIG_DIR=$T/no-such-cfg $S -c $T/team.yaml check 2>&1 | grep -q "^hooks " \
  && ok "check: a hooks line naming the ungated seats when the user's settings disable all hooks, none otherwise" || { bad "check: hooks line"; echo "$hk"; }
[ -d $T/state/notes ] && ok "up makes the notes folder under the state folder" || bad "no $T/state/notes after up"
grep -qF "$T/state/notes/em.md" $T/state/prompts/em.md && ok "the rendered prompt names the seat's own note" || bad "the prompt does not name $T/state/notes/em.md"
# The allow covers Edit (and Write), not a Bash redirect, which prompts outside bypass (qa, live on #90).
grep -qF "Write it with the Write or Edit tool, not Bash" $T/state/prompts/em.md && ok "the prompt says to write the note with Write or Edit, not Bash" || bad "the prompt does not say how to write the note"
# Seats are told their SendMessage traffic is logged too (#39), not that only say is.
tr '\n' ' ' < $T/state/prompts/em.md | tr -s ' ' | grep -qF 'Every `say` and every `SendMessage` you send is logged, message included,' \
  && ! grep -qF "traffic is not, and is only in each session's transcript" $T/state/prompts/em.md && ok "the prompt says SendMessage traffic is logged as say's is" || bad "the prompt still says SendMessage is not logged"
grep -qF "progress note" $T/state/prompts/em.kickoff && ok "the default kickoff asks for the note's task and next step" || { bad "kickoff and the note"; cat $T/state/prompts/em.kickoff; }
echo "Task: survive a restart" > $T/state/notes/em.md
rules $T/state/settings/w1.json deny | grep -qxF "Edit(/$RT/state/gate/**)" && ok "the gate's own state (its failure counter) is Edit-protected" || bad "gate state not protected"
echo "$chk" | grep -qE "^w1 .* on-stop " && echo "$chk" | grep -qE "^em .* - +[^ ]" && ok "check: GATE column (on-stop for w1 only)" || { bad "check GATE column"; echo "$chk" | head -14; }
echo "$chk" | grep -qF "make check (timeout 120s; a seat may stop after 2 failed gates in a row)" && ok "check: gate command, timeout and limit in the header" || bad "check: gate header"
# Each start rewrites the file: a stale or edited one is replaced, not reused.
chmod u+w $T/state/settings/em.json && echo '{"permissions":{}}' > $T/state/settings/em.json && chmod 444 $T/state/settings/em.json
$S -c $T/team.yaml down --yes em >/dev/null; TEAM_VIEW=0 $S -c $T/team.yaml up --no-view em >/dev/null 2>&1
[ "$(perms $T/state/settings/em.json)" = "$want_em" ] && [ "$(stat -f %Lp $T/state/settings/em.json)" = 444 ] && ok "up rewrites a stale settings file" || { bad "up rewrites settings"; perms $T/state/settings/em.json; }
[ "$(cat $T/state/notes/em.md 2>&1)" = "Task: survive a restart" ] && ok "a seat's progress note survives down and up" || { bad "progress note after down/up"; ls -la $T/state/notes 2>&1; }
e2e_end=settings # the last line: test/e2e.sh checks that the file ran to here
