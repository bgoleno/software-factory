# Runs one heavy command (a full gate, an e2e run) at a time across every seat of every team on this
# host, and anyone's shell (#214). factory.sh run-exclusive execs this before it reads a team file:
#
#   ruby lib/run_exclusive.rb [--] <command> [args...]
#
# The command is an argument list, never a shell string (a pipeline is `bash -c '...'`), and the exit
# status is the command's (128 + the signal when a signal ended it). While another run holds the lock,
# this waits, however long it takes, and says who holds it and since when; it never fails for a busy
# lock. Ctrl-C or TERM while waiting exits 130 or 143 without running the command.
#
# The lock is a flock on one file per user, outside every team's state folder and checkout:
# <home>/Library/Application Support/software-factory/run-exclusive.lock, home from the user database,
# not $HOME, so every seat, team and checkout of this user finds the same file. Not the per-user T/
# folder: macOS removes files there that have not been used for some days, and a lock whose name is
# removed while a run holds it no longer makes the next run wait (tl on #214). FACTORY_RUN_LOCK names
# another file instead (the e2e uses its own).
#
# System ruby 2.6: no gems, no endless methods.
require "json"
require "etc"

LOCK_POLL = 2       # seconds between tries while the lock is busy
REMIND = 300        # seconds between "still waiting" lines

def say(msg)
  $stderr.puts "run-exclusive: #{msg}"
end

def die(msg, code = 1)
  say "error: #{msg}"
  exit code
end

args = ARGV.dup
args.shift if args.first == "--"
die("usage: factory.sh run-exclusive -- <command> [args...]", 64) if args.empty?

lock = ENV["FACTORY_RUN_LOCK"].to_s
if lock.empty?
  home = (Etc.getpwuid(Process.uid).dir rescue nil).to_s
  die("cannot find this user's home folder in the user database, so there is no place for the lock") if home.empty?
  lock = File.join(home, "Library", "Application Support", "software-factory", "run-exclusive.lock")
end
lock = File.expand_path(lock)
holder = "#{lock}.holder"

def alive?(pid)
  return false unless pid.is_a?(Integer) && pid > 0
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

# The holder record: who took the lock, written by the holder just after it took it. A waiter can read
# the record of a run that has ended (it is removed at the end, but a killed run leaves it), or none.
def record(holder)
  j = File.open(holder, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) { |f| f.stat.file? ? f.read(65_536) : nil }
  j && JSON.parse(j)
rescue StandardError
  nil
end

def who(rec)
  return "an unknown holder" unless rec.is_a?(Hash) && alive?(rec["pid"])
  "#{rec["who"]} (pid #{rec["pid"]}, in #{rec["cwd"]}), holding since #{rec["since"]}: #{rec["cmd"]}"
end

# Nesting: a run-exclusive inside the command of another (a gate script that calls it again) would wait
# for itself forever. The holder hands its command FACTORY_RUN_EXCLUSIVE_HELD=<lock>:<its pid>, and an
# inner call on the same lock runs its command directly, but only while the record names that pid and
# that pid is alive. The variable alone is not enough: anything the command leaves running (a tmux
# server started under the lock) keeps it for every shell it starts later, and those would then skip
# the lock for good (tl on #214).
held = ENV["FACTORY_RUN_EXCLUSIVE_HELD"].to_s
if (m = held.match(/\A(.+):(\d+)\z/)) && m[1] == lock
  rec = record(holder)
  if rec.is_a?(Hash) && rec["pid"] == m[2].to_i && alive?(m[2].to_i)
    begin
      exec([args[0], args[0]], *args[1..-1])
    rescue SystemCallError => e
      die("cannot run #{args[0]}: #{e.message}", 127)
    end
  end
end

# The folder is made owner-only. Neither it nor the lock may be a link, or anything but a folder and a
# regular file with one name: the lock would then be taken on some other file (#194's checks).
dir = File.dirname(lock)
begin
  Dir.mkdir(dir, 0o700)
rescue Errno::EEXIST
  nil
rescue SystemCallError => e
  die("cannot make #{dir}: #{e.message}")
end
st = File.lstat(dir)
die("#{dir} is a symlink or not a folder, and the lock is never taken through one: remove that exact path") if st.symlink? || !st.directory?

def unsafe?(path)
  st = File.lstat(path)
  st.symlink? || !st.file? || st.nlink > 1
rescue Errno::ENOENT
  false
end

def open_lock(lock)
  die("#{lock} is a symlink, a hard link or not a regular file, and the lock is never taken through one: remove that exact path") if unsafe?(lock)
  # NOFOLLOW: a link made after the check fails the open. NONBLOCK: a FIFO does not hang it. Ruby opens
  # every file close-on-exec, so the command never holds the lock: anything it leaves running would
  # hold it otherwise, as with lockf(1), which hands it on (the e2e's tmux server outlives the run).
  f = File.open(lock, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600)
  st = f.stat
  unless st.file? && st.nlink == 1
    f.close
    die("#{lock} is not a regular file with one name, and the lock is never taken through one: remove that exact path")
  end
  f
rescue Errno::ELOOP
  die("#{lock} is a symlink, and the lock is never taken through one: remove that exact path")
rescue SystemCallError => e
  die("cannot open #{lock}: #{e.message}")
end

# Until the command runs, a signal ends this run (130, 143, 129) without running it; from then on it is
# passed on to the command's process group, and the command's own end decides the exit status.
child = nil
{ "INT" => 130, "TERM" => 143, "HUP" => 129 }.each do |s, code|
  trap(s) { child ? (Process.kill(s, -child) rescue nil) : exit(code) }
end

started = Time.now
waited = false
reminded = started
f = nil
loop do
  f = open_lock(lock)
  if f.flock(File::LOCK_EX | File::LOCK_NB)
    # The lock is on the open file, not the name. A waiter can open the file, have its name removed
    # and made again by another run, then lock the old file once its holder ends: it would hold a lock
    # nobody else takes, and overlap the run on the new file. So the name must still lead to the file
    # locked; if not, take the lock again, on what the name leads to now (tl on #214).
    cur = (File.lstat(lock) rescue nil)
    fs = f.stat
    break if cur && cur.file? && !cur.symlink? && cur.dev == fs.dev && cur.ino == fs.ino
    f.close
    next
  end
  f.close
  now = Time.now
  if !waited
    say "waiting for the lock (#{lock}), held by #{who(record(holder))}"
    waited = true
  elsif now - reminded >= REMIND
    say "still waiting, since #{started.strftime("%H:%M:%S")} (#{(now - started).round}s), for #{who(record(holder))}"
    reminded = now
  end
  sleep LOCK_POLL
end

me = Process.pid
rec = {
  "pid" => me,
  "who" => [ENV["TEAM_ROLE"].to_s.empty? ? "a shell" : ENV["TEAM_ROLE"],
            (ENV["TEAM_CONFIG"].to_s.empty? ? nil : File.basename(ENV["TEAM_CONFIG"], ".*"))].compact.join(" of "),
  "since" => Time.now.strftime("%Y-%m-%dT%H:%M:%S"),
  "cwd" => Dir.pwd,
  "cmd" => args.join(" ")[0, 300],
}
# Written to a temporary name and renamed: rename replaces a link at the record's name rather than
# writing through it, and a waiter never reads half a record.
tmp = "#{holder}.#{me}"
begin
  File.unlink(tmp) if File.symlink?(tmp) || File.exist?(tmp)
  File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |o| o.write(JSON.generate(rec)) }
  File.rename(tmp, holder)
rescue SystemCallError => e
  say "could not write the holder record #{holder} (#{e.message}); waiters will see an unknown holder"
end
say "got the lock after #{(Time.now - started).round}s" if waited
locked = f.stat

# The command runs in a process group of its own, so INT, TERM and HUP reach all of it (a test and what
# it started), passed on from here. Not in the terminal's foreground group: a command that reads the
# terminal stops; the gate and the e2e do not read it.
env = { "FACTORY_RUN_EXCLUSIVE_HELD" => "#{lock}:#{me}" }
begin
  child = Process.spawn(env, [args[0], args[0]], *args[1..-1], pgroup: true)
rescue SystemCallError => e
  File.unlink(holder) rescue nil
  die("cannot run #{args[0]}: #{e.message}", 127)
end
status = nil
loop do
  begin
    _, status = Process.wait2(child)
    break
  rescue Errno::EINTR
    next
  end
end
# The name must also have lasted while this run held the lock: once it is gone, a run that starts makes
# a new file and does not wait for this one, and nothing can see that in time (a holder cannot give its
# open file the name back). So it is only reported, at the end, for whoever reads this run's output.
cur = (File.lstat(lock) rescue nil)
unless cur && cur.dev == locked.dev && cur.ino == locked.ino
  say "warning: #{lock} was removed or replaced while this run held the lock, so a run that started meanwhile may have overlapped it"
end
# Removed while the lock is still held, so it can only be this run's record.
File.unlink(holder) rescue nil
f.close
exit(status.exited? ? status.exitstatus : 128 + (status.termsig || 0))
