#!/usr/bin/env ruby
# frozen_string_literal: true

# Answers the questions factory.sh asks about a team definition file.
#
#   team_config.rb <team.yaml> validate
#   team_config.rb <team.yaml> ids                 role ids, in file order (start order)
#   team_config.rb <team.yaml> get <dotted.key>    e.g. storage.volume, sessions.prefix
#   team_config.rb <team.yaml> role <id> <key>     title | session | workdir_type | worktree_name | model | effort |
#                                                  permission_mode
#   team_config.rb <team.yaml> workdir <id>        absolute working directory of a seat
#   team_config.rb <team.yaml> claude_args <id>    the seat's claude arguments, one per line
#   team_config.rb <team.yaml> render <id>         the seat's full system prompt
#   team_config.rb <team.yaml> kickoff <id>        the seat's first message
#   team_config.rb <team.yaml> settings <id>       the seat's generated Claude Code settings (JSON)
#   team_config.rb <team.yaml> permissions_report  each seat's mode and rules, for `check`
#   team_config.rb <team.yaml> warnings            what `check` warns about (held messages, merging)
#   team_config.rb <team.yaml> matching_rules <id> <command>  the seat's deny/ask rules a command
#                                                  matches (an approximation, see #rule_matches?)
#
# Ruby is used because it ships with macOS and parses YAML without installing anything.
# Unknown keys are an error, not ignored: a misspelled `volume:` that silently fell back to a
# default would put worktrees on the wrong disk.
require 'yaml'
require 'json'

def die(msg)
  warn "team config error: #{msg}"
  exit 1
end

# Team and prompt files are UTF-8 whatever the locale. Under LC_ALL=C, or with no locale set (cron,
# env -i), File.read would tag them US-ASCII and the first non-ASCII byte in a prompt would make
# the placeholder pass raise, which stops render and every command that validates the file (#72).
def read_utf8(path)
  s = File.read(path, encoding: 'UTF-8')
  return s if s.valid_encoding?

  line = s.each_line.find_index { |l| !l.valid_encoding? }.to_i + 1
  die "#{path} is not valid UTF-8 (line #{line})"
end

# Strings from outside the team file are tagged by the locale too: environment values, the home
# folder, the command line and the install folder come back US-ASCII or ASCII-8BIT under LC_ALL=C or
# with no locale. One with a non-ASCII byte then clashes with the UTF-8 team file in a substitution,
# a join or JSON (#82), so each is read as UTF-8 where it enters, and invalid UTF-8 stops with its
# source named. Path functions keep UTF-8 when their inputs are UTF-8, so the entry points suffice.
def utf8(s, source)
  u = s.to_s.dup.force_encoding('UTF-8')
  return u if u.valid_encoding?

  die "#{source} is not valid UTF-8: #{u.scrub('?')}"
end

def env_utf8(name, default = nil)
  ENV.key?(name) ? utf8(ENV[name], "the environment variable #{name}") : default
end

def home_utf8
  utf8(Dir.home, 'the home folder (HOME)')
end

TOP_KEYS = %w[team owner repo project storage sessions display prompts kickoff permissions roles other_teams].freeze
DISPLAY_KEYS = %w[iterm primary window].freeze
PROJECT_KEYS = %w[name url].freeze
EFFORTS = %w[low medium high xhigh max].freeze
REPO_KEYS = %w[path github base gate gate_timeout gate_max_blocks bootstrap copy].freeze
STORAGE_KEYS = %w[volume root].freeze
SESSION_KEYS = %w[prefix claude].freeze
CLAUDE_KEYS = %w[wrapper args model effort permission_mode plugin auto_memory].freeze
PROMPT_KEYS = %w[common project].freeze
# The #117 budget for one seat's rendered prompt: every line is loaded on every task.
PROMPT_MAX_LINES = 199
ROLE_KEYS = %w[title summary workdir prompt prompt_text kickoff session model effort permission_mode permissions
               gate_on_stop skills may_merge auto_memory].freeze
WORKDIR_KEYS = %w[type path name].freeze
ID_RE = /\A[a-z][a-z0-9]*\z/.freeze
PREFIX_RE = /\A[a-z0-9][a-z0-9-]*\z/.freeze
# A skill as the Skill tool names it: a bare name, or plugin:name.
SKILL_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9][A-Za-z0-9._-]*)?\z/.freeze

# The folder factory.sh and this file are installed in.
INSTALL = utf8(File.expand_path('..', __dir__), 'the install folder')

# The factory's own plugin (skills, later agents and hooks). Each seat loads it with --plugin-dir, so it
# reaches exactly the sessions factory.sh starts: seats work in the target project's folders, where this
# repository's .claude/ is never read, and nothing is installed into the user's settings.
PLUGIN_DIR = File.join(INSTALL, 'plugin')

# Starts every kickoff. The kickoff is the seat's first user message, and seats tell the owner's voice
# by input that carries no label, so without this a team file's kickoff would read as the owner
# typing. `say` never sends with this label (the role id is reserved, and say refuses it as a sender).
# It is not authenticated: it keeps the kickoff from looking like owner input by default.
KICKOFF_LABEL = '[from launcher]'

# The documented permission modes (https://code.claude.com/docs/en/permission-modes). `default`
# is the config value and `manual` its CLI alias. Both are passed through as written: the 2.1.316
# CLI accepts `--permission-mode default` although its error message lists only `manual`.
PERMISSION_MODES = %w[default manual acceptEdits plan auto dontAsk bypassPermissions].freeze

# Strongest first. Claude Code checks deny, then ask, then allow, across every settings source, and
# the first match decides (https://code.claude.com/docs/en/permissions).
PERMISSION_LISTS = %w[deny ask allow].freeze

# The ways a seat could merge a PR (or a branch) from Bash, as tl decided in #85. `check` warns about
# a role whose rules neither deny nor ask on each of them, unless the team file says the role may
# merge (roles.<id>.may_merge). teams/example.yaml denies or asks on the same list.
# - `gh pr merge *` also matches a bare `gh pr merge` (a trailing ` *` that is the only wildcard).
# - `gh pr -* merge *` is any flag before the subcommand (-R o/r, --repo o/r, --repo=o/r). The space
#   after merge keeps `gh pr -R o/r view 5 --json mergeable` out; `gh pr -* merge` is the same with
#   no argument after merge (the current branch's PR), since a rule with two `*` has no bare form.
# - GraphQL: merge, auto-merge, and mergeBranch (a branch merged without a PR); REST: the PR merge
#   endpoint, and POST /repos/{o}/{r}/merges (a branch merged without a PR).
MERGE_PATTERNS = [
  'Bash(gh pr merge *)', 'Bash(gh pr -* merge *)', 'Bash(gh pr -* merge)',
  'Bash(gh api *pulls/*/merge*)', 'Bash(gh api *repos/*/merges*)',
  'Bash(gh api graphql*mergePullRequest*)', 'Bash(gh api graphql*enablePullRequestAutoMerge*)',
  'Bash(gh api graphql*mergeBranch*)'
].freeze

# Flags factory.sh sets itself, or that would undo this file's permission keys. :always, or
# :with_mode (only when a seat has a permission_mode; a legacy file may still pass them in args).
RESERVED_FLAGS = {
  '--settings' => [:always, 'factory.sh passes each seat its generated settings file'],
  '--setting-sources' => [:always, "it changes which settings files load, and can drop the user's own deny rules"],
  '--permission-prompt-tool' => [:always, 'it hands ask decisions to a program'],
  '--permission-mode' => [:with_mode, 'use permission_mode'],
  '--dangerously-skip-permissions' => [:with_mode, 'use permission_mode: bypassPermissions'],
  '--allow-dangerously-skip-permissions' => [:with_mode, 'use permission_mode']
}.freeze

# Folders factory.sh owns under the state folder: settings, launch and prompts are rewritten for every
# start; bin holds the copies of claude the seats run, made by up when missing (#50); setup holds the
# mark up writes once a new worktree's repo.copy and repo.bootstrap have finished (#10). Seats may not
# edit them (see protected_paths), so a folder added here is protected without further changes.
# Files seats are meant to write (such as progress notes) belong in a folder that is not listed.
GENERATED_DIRS = %w[settings launch prompts bin setup].freeze

# Folders under the state folder that hooks write, and seats must not: the gate's failure counter
# lives in gate/, so a seat that could edit it could switch its own gate off. Protected like
# GENERATED_DIRS, but not regenerated per start.
HOOK_DIRS = %w[gate].freeze

# The one role that may read messages.log. The log holds every native message in full, private
# reports to the EM among them, so every other seat gets a Read deny on it (the owner's decision on
# #110). An accident guard, not a boundary: every seat runs as the same OS user (#29), so a command
# or script that reads the file another way is not stopped. A team with no role of this id has
# every seat denied; the owner still reads the log directly.
LOG_READER = 'em'.freeze

# The one role that writes security-triage records (#138), in <state>/triage/ (TRIAGE_DIR). A record
# can hold an unfixed medium-or-higher finding, which hard rule 5 keeps to sec and the EM. So that
# role may edit and read the folder without a prompt in every mode (it is outside its working
# directory), LOG_READER may read it (sec sends it a record's path), and every other seat is denied
# both: an accident guard, like the log's, so a seat searching the state folder does not pull a
# record into its context or change one the EM acts on. A team whose security seat has another id
# gets no record folder, and every seat is denied it, but LOG_READER keeps its Read allow. up makes
# the folder; nothing deletes it.
TRIAGE_WRITER = 'sec'.freeze
TRIAGE_DIR = 'triage'.freeze

# Where each seat keeps its progress note, <state>/notes/<role>.md (#5). Outside the worktree, so it
# survives the worktree being recreated, and in neither list above, so a seat may write it.
NOTES_DIR = 'notes'.freeze

# other_teams entries (#197), and the folders up makes in every team's state folder, by which one is
# recognised beside this team's own (see other_teams_found).
OTHER_TEAM_KEYS = %w[state observers].freeze
STATE_MARKERS = %w[settings launch prompts].freeze

# The field a tool's own specifier already covers. Claude Code ignores a `Tool(field:...)` rule on
# it, with only a startup warning.
PRIMARY_FIELDS = {
  'Bash' => 'command', 'PowerShell' => 'command', 'Read' => 'file_path', 'Edit' => 'file_path',
  'Write' => 'file_path', 'Grep' => 'path', 'Glob' => 'path', 'NotebookEdit' => 'notebook_path', 'WebFetch' => 'url'
}.freeze

# Claude Code accepts a path rule for these but never matches it: only Edit and Read rules are
# checked against paths.
NEVER_MATCH = %w[Write NotebookEdit Glob MultiEdit].freeze

# Why a permission rule string is wrong, or nil. Claude Code drops a malformed rule with at most a
# warning (none at all under -p), so a rule is checked here, where a mistake stops the launch.
def rule_error(rule, list)
  return 'a rule must be a non-empty string' unless rule.is_a?(String) && !rule.empty?
  return 'it has leading or trailing whitespace' if rule != rule.strip

  # Parentheses inside a specifier are literal, so the specifier runs from the first ( to a final ).
  open = rule.index('(')
  name = open ? rule[0...open] : rule
  if open ? !rule.end_with?(')') : rule.include?(')')
    return 'it must be Tool or Tool(specifier)'
  end

  spec = open ? rule[(open + 1)...-1] : nil
  return 'it has an empty specifier: write the bare tool name to match every use' if spec && spec.strip.empty?

  if name.start_with?('mcp__')
    return 'mcp__ rules cannot have a (specifier): Claude Code skips them when it loads a settings file' if spec
    return 'it must be Tool or Tool(specifier)' unless name =~ /\Amcp__[A-Za-z0-9_*.-]+\z/

    server = name[/\Amcp__(.*?)__/, 1]
    if list == 'allow' && name.include?('*') && (server.nil? || server.empty? || server.include?('*'))
      return 'a tool-name glob is only allowed in deny and ask, or after mcp__<server>__ in allow'
    end
    return nil
  end
  return 'it must be Tool or Tool(specifier)' unless name =~ /\A[A-Za-z0-9_*]+\z/
  return "the tool name must start with an uppercase letter, as Claude Code's tool names do" unless name =~ /\A[A-Z*]/
  return 'a tool-name glob is only allowed in deny and ask, or after mcp__<server>__ in allow' if list == 'allow' && name.include?('*')
  return nil if spec.nil?

  if NEVER_MATCH.include?(name)
    return "#{name}(path) never matches: write Edit(path) (Read(path) for Glob), or the bare tool name"
  end
  field = PRIMARY_FIELDS[name]
  if field && spec =~ /\A\s*#{field}\s*:/
    return "#{field} is the tool's main input field, and Claude Code ignores a #{field}: rule; " \
           'write Bash(rm *), Read(./path) or WebFetch(domain:host)'
  end
  if %w[Read Edit].include?(name) && spec.start_with?('/') && !spec.start_with?('//')
    return 'a single leading / anchors at the folder of the generated settings file, so it matches nothing ' \
           'in the project; write //absolute, ~/home, ./relative or a bare name'
  end
  if %w[Bash PowerShell].include?(name) && spec.include?(':*') && !spec.end_with?(':*')
    return ':* is only a wildcard at the end of a rule; elsewhere the colon is literal (write a space before the *)'
  end
  nil
end

# A path with the characters that are special in a gitignore pattern (Read and Edit rules use
# that syntax) escaped.
def glob_escape(path)
  path.gsub(/[\\*?\[\]]/) { |c| "\\#{c}" }
end

# The real path of a file that may not exist yet: the longest existing prefix is resolved, so a
# symlinked folder (/tmp, /var on macOS) gives the path Claude Code compares rules against.
def real_path(path)
  base = path
  rest = []
  until File.exist?(base) || base == '/'
    rest.unshift(File.basename(base))
    base = File.dirname(base)
  end
  File.join(File.realpath(base), *rest)
end

class TeamConfig
  attr_reader :path, :dir

  def initialize(path)
    @path = utf8(File.expand_path(path), 'the team file path')
    @dir = File.dirname(@path)
    die "cannot read #{@path}" unless File.file?(@path)
    begin
      @c = YAML.safe_load(read_utf8(@path), permitted_classes: [], aliases: false)
    rescue Psych::Exception => e
      die "#{@path} is not valid YAML: #{e.message}"
    end
    die 'top level must be a mapping' unless @c.is_a?(Hash)
  end

  def expand(p)
    File.expand_path(p.to_s.sub(/\A~(?=\/|\z)/, home_utf8), @dir)
  end

  def section(name, allowed, required: true)
    s = @c[name]
    if s.nil?
      die "missing '#{name}'" if required
      return {}
    end
    die "'#{name}' must be a mapping" unless s.is_a?(Hash)
    bad = s.keys - allowed
    die "unknown key(s) under '#{name}': #{bad.join(', ')} (allowed: #{allowed.join(', ')})" unless bad.empty?
    s
  end

  def repo

    section('repo', REPO_KEYS)

  end
  def project
    section('project', PROJECT_KEYS)
  end

  def github
    repo['github'].to_s
  end

  def storage
    section('storage', STORAGE_KEYS)
  end
  def sessions
    section('sessions', SESSION_KEYS, required: false)
  end
  def claude
    (sessions['claude'] || {}).tap { |h| die "'sessions.claude' must be a mapping" unless h.is_a?(Hash) }
  end
  def display
    section('display', DISPLAY_KEYS, required: false)
  end

  # sessions.claude.plugin: load the factory's plugin into every seat (default true).
  def plugin?
    claude.key?('plugin') ? claude['plugin'] : true
  end

  def view_iterm
    display.key?('iterm') ? display['iterm'] : true
  end

  def view_primary
    (display['primary'] || roles.keys.first).to_s
  end

  def view_window
    (display['window'] || 'full').to_s
  end

  def owner
    (@c['owner'] || 'the owner').to_s
  end

  def prefix
    (sessions['prefix'] || 'team').to_s
  end
  def roles
    @c['roles']
  end

  def volume

    File.expand_path(storage['volume'].to_s.sub(/\A~(?=\/|\z)/, home_utf8))

  end
  def root
    storage['root'].to_s
  end
  def worktree_root
    File.join(volume, root)
  end
  def repo_path
    expand(repo['path'])
  end

  def role(id)
    r = roles[id]
    die "unknown role '#{id}' (roles: #{roles.keys.join(' ')})" if r.nil?
    r
  end

  def workdir_spec(id)

    role(id)['workdir']

  end
  def workdir_type(id)
    workdir_spec(id)['type']
  end
  def worktree_name(id)
    (workdir_spec(id)['name'] || "team-#{id}").to_s
  end
  def title(id)
    role(id)['title'].to_s
  end
  def session(id)
    (role(id)['session'] || "#{prefix}-#{id}").to_s
  end

  def workdir(id)
    w = workdir_spec(id)
    w['type'] == 'project' ? expand(w['path']) : File.join(worktree_root, worktree_name(id))
  end

  def read_prompt_file(rel)
    f = expand(rel)
    die "prompt file not found: #{f}" unless File.file?(f)
    read_utf8(f)
  end

  def role_prompt(id)
    r = role(id)
    r['prompt_text'] ? r['prompt_text'].to_s : read_prompt_file(r['prompt'])
  end

  def roster
    rows = roles.map do |id, r|
      "| #{id} | #{r['title']}#{r['summary'] ? ": #{r['summary']}" : ''} | #{session(id)} |"
    end
    (["| role id | seat | session |", '|---|---|---|'] + rows).join("\n")
  end

  def vars(id)
    {
      'TITLE' => title(id), 'ROLE' => id, 'SESSION' => session(id), 'PREFIX' => prefix,
      'SCRIPT' => env_utf8('TEAM_SCRIPT', 'factory.sh'), 'LOG' => env_utf8('TEAM_LOG', 'messages.log'),
      'REPO' => repo_path, 'WORKDIR' => workdir(id), 'WORKTREE_ROOT' => worktree_root,
      'VOLUME' => volume, 'GITHUB_REPO' => github, 'GITHUB_URL' => "https://github.com/#{github}",
      'PROJECT_NAME' => project['name'].to_s, 'PROJECT_URL' => project['url'].to_s, 'TEAM' => @c['team'].to_s, 'OWNER' => owner, 'ROSTER' => roster,
      'GATE_MAX_BLOCKS' => gate_max_blocks.to_s, 'NOTE' => note_path(id)
    }
  end

  # Every value is checked as UTF-8 before it goes in, whatever produced it, so a value from a new
  # source cannot bring back the encoding clash in gsub (#82).
  def subst(text, id)
    v = vars(id).map { |k, s| [k, utf8(s, "the value of @@#{k}@@")] }.to_h
    out = text.gsub(/@@([A-Z_]+)@@/) { v.key?(Regexp.last_match(1)) ? v[Regexp.last_match(1)] : die("unknown placeholder @@#{Regexp.last_match(1)}@@ in a prompt") }
    out
  end

  # common, then the project's addendum (prompts.project), then the role's own prompt and skills.
  # Without prompts.project the text is exactly what it was before the key existed (#190).
  def render(id)
    common = prompts_common
    own = role_prompt(id)
    own = "#{own.chomp}\n\n#{skills_section(id)}" unless skills(id).empty?
    project = prompts_project
    middle = project ? "#{check_project_text(project, id).chomp}\n\n" : ''
    subst(common + "\n" + middle + own, id)
  end

  # The project file is the team's own text in every seat's system prompt, so, like a kickoff, it may
  # not carry a [from ...] label that could read as another sender's. Checked after substitution and
  # on a normalised copy, as the kickoff is. Returns the text unsubstituted (render substitutes all).
  def check_project_text(text, id)
    norm = subst(text, id).unicode_normalize(:nfkc).gsub(/\p{Cf}/, '')
    die "prompts.project must not contain a [from ...] label: it would read as another sender's" if norm =~ /\[\s*from\b/i
    text
  end

  # Lines a seat's rendered prompt has, counted as wc -l counts the output of `render`.
  def render_lines(id)
    t = render(id)
    t.count("\n") + (t.end_with?("\n") ? 0 : 1)
  end

  # roles.<id>.skills: each item is a skill name, or a one-entry mapping of a name to when to use
  # it. Returns [[name, note or nil], ...]; validate checks the shape first.
  def skills(id)
    (role(id)['skills'] || []).map { |s| s.is_a?(Hash) ? [s.keys.first.to_s, s.values.first.to_s] : [s.to_s, nil] }
  end

  # Seats load the owner's user-level and plugin skills, but which ones are installed differs per
  # machine, so the wording never assumes a listed skill is there and says what to do when it is not.
  def skills_section(id)
    head = ['## Skills',
            'These skills fit this role. Use one with the Skill tool when it applies, if it is installed (your',
            'session lists the skills it has). If one is not installed, work without it: do not install it.']
    (head + skills(id).map { |n, w| w ? "- `#{n}`: #{w}" : "- `#{n}`" }).join("\n") + "\n"
  end

  def validate_skills(id, list)
    die "roles.#{id}.skills must be a list" unless list.is_a?(Array)
    seen = {}
    list.each do |s|
      if s.is_a?(Hash)
        die "roles.#{id}.skills: a mapping entry must be one skill name and its note" unless s.size == 1
        name, note = s.first
        # The note is written into the prompt as is, so any control character (a newline, but also a
        # carriage return, tab or escape) would reach the seat raw.
        unless note.is_a?(String) && !note.strip.empty? && note !~ /[[:cntrl:]]/
          die "roles.#{id}.skills: the note for '#{name}' must be one line of text, with no control characters"
        end
      else
        name = s
      end
      die "roles.#{id}.skills: '#{name}' is not a skill name (letters, digits, . _ - and one plugin: prefix)" unless name.is_a?(String) && name =~ SKILL_RE
      die "roles.#{id}.skills: '#{name}' is listed twice" if seen[name]
      seen[name] = true
    end
  end

  def prompts_common
    p = @c['prompts']
    return '' if p.nil?

    read_prompt_file(p['common'])
  end

  def prompts_project
    p = @c['prompts']
    p && p['project'] ? read_prompt_file(p['project']) : nil
  end

  def prompts_project_path
    p = @c['prompts']
    p && p['project'] ? expand(p['project']) : nil
  end

  # For check: where each part of the prompts comes from, and the longest rendered seat.
  def prompts_summary
    lens = roles.keys.map { |id| [id, render_lines(id)] }
    long = lens.max_by { |_, n| n }
    "common #{prompts_common_path || 'none'}; project #{prompts_project_path || 'none'}; " \
      "longest rendered prompt #{long[1]} lines (#{long[0]})"
  end

  def prompts_warning
    over = roles.keys.map { |id| [id, render_lines(id)] }.select { |_, n| n > PROMPT_MAX_LINES }
    return '' if over.empty?

    "warning: #{over.map { |id, n| "#{id} (#{n})" }.join(', ')} render prompts over #{PROMPT_MAX_LINES} lines. " \
      'Every line is loaded on every task (#117): move procedure into skills, or shorten prompts.project.'
  end

  def kickoff(id)
    r = role(id)
    tpl = r['kickoff'] || @c['kickoff'] ||
          'Team session started: you are the @@TITLE@@ (session @@SESSION@@). Your full role instructions are in your system prompt. ' \
          'Reply with one line confirming your role and working directory (and, if your progress note names a task, that task and its next step), then wait for a message from the EM or @@OWNER@@. ' \
          'Do not start any work until you receive one.'
    text = subst(tpl.to_s, id)
    # A label inside the text would make part of it read as another sender's (`[from owner]`). The
    # check runs on the substituted text, so a label cannot arrive through a role's title or the
    # owner's name, and on a normalised copy, so `[ From`, full-width brackets and zero-width
    # characters are caught too. Its one false positive, a word like `[from-scratch]`, is harmless.
    norm = text.unicode_normalize(:nfkc).gsub(/\p{Cf}/, '')
    die "the kickoff for #{id} must not contain a [from ...] label: #{KICKOFF_LABEL} is added in front of it" if norm =~ /\[\s*from\b/i
    "#{KICKOFF_LABEL} #{text}"
  end

  # A role's own value wins over sessions.claude. Neither set means the flag is omitted and the
  # seat inherits the user's claude settings (model and effortLevel in ~/.claude/settings.json).
  def model(id)
    (role(id)['model'] || claude['model'])&.to_s
  end

  def effort(id)
    (role(id)['effort'] || claude['effort'])&.to_s
  end

  def permission_mode(id)
    (role(id)['permission_mode'] || claude['permission_mode'])&.to_s
  end

  # Claude Code's auto memory lives in <config>/projects/<repo>/memory/, one folder for the whole
  # repository: "all worktrees and subdirectories within the same repo share one auto memory
  # directory", and its MEMORY.md loads into every session there
  # (https://code.claude.com/docs/en/memory#storage-location). A seat's note would reach every other
  # seat and the owner's own sessions in the main checkout, unreviewed (#71), so it is off unless the
  # team file turns it on (a role's value wins over sessions.claude). On means the factory sets
  # nothing and Claude Code's own settings decide.
  def auto_memory?(id)
    v = role(id).key?('auto_memory') ? role(id)['auto_memory'] : claude['auto_memory']
    v == true
  end

  def args
    a = claude['args'] || []
    die "'sessions.claude.args' must be a list" unless a.is_a?(Array)
    a.map(&:to_s)
  end

  # The mode as `check` shows it. A legacy file sets it with a flag in args instead.
  def mode_label(id)
    return permission_mode(id) if permission_mode(id)
    return 'bypassPermissions (args)' if args.include?('--dangerously-skip-permissions')

    i = args.index { |a| a == '--permission-mode' || a.start_with?('--permission-mode=') }
    return '(inherit)' if i.nil?

    "#{args[i].include?('=') ? args[i].split('=', 2)[1] : args[i + 1]} (args)"
  end

  def claude_args(id)
    out = args
    out += ['--model', model(id)] if model(id)
    out += ['--effort', effort(id)] if effort(id)
    out += ['--permission-mode', permission_mode(id)] if permission_mode(id)
    out += ['--plugin-dir', real_path(PLUGIN_DIR)] if plugin?
    out
  end

  # Generated prompts, launchers, settings and the message log live here.
  def state_dir
    File.expand_path(env_utf8('TEAM_STATE_DIR') || File.join(INSTALL, '.state', @c['team'].to_s))
  end

  # The seat's progress note (#5). Seats write it; up only makes its folder; nothing deletes it.
  def note_path(id)
    File.join(state_dir, NOTES_DIR, "#{id}.md")
  end

  # Edit rules for a seat's note: as configured and as its real path, glob characters escaped.
  def note_rules(id)
    [File.expand_path(note_path(id)), real_path(note_path(id))].uniq.map { |p| "Edit(/#{glob_escape(p)})" }
  end

  # <state>/triage/** in both spellings (as configured and real): the folder glob-escaped, then an
  # unescaped /** for everything in it.
  def triage_paths
    d = File.join(state_dir, TRIAGE_DIR)
    [File.expand_path(d), real_path(d)].uniq.map { |p| "#{glob_escape(p)}/**" }
  end

  # The triage folder's rules for seat id, as { 'allow' => [...], 'deny' => [...] } (see TRIAGE_WRITER).
  def triage_rules(id)
    edit = triage_paths.map { |p| "Edit(/#{p})" }
    read = triage_paths.map { |p| "Read(/#{p})" }
    return { 'allow' => edit + read, 'deny' => [] } if id == TRIAGE_WRITER
    return { 'allow' => read, 'deny' => edit } if id == LOG_READER

    { 'allow' => [], 'deny' => edit + read }
  end

  # Other teams' state folders (#197). The denies above name only this team's own state folder, so a
  # seat could read another team's triage records (which can hold unfixed findings) and message log,
  # and write any of it, when two teams share a machine. A glob over the state root cannot cover
  # them: it would also deny this team's own folder (a deny wins over an allow; rules have no
  # negation). So each other team's folder is named, from two sources:
  # - found: every real folder beside this team's own in the state root (the folder holding
  #   state_dir, normally <install>/.state/) that holds settings/, launch/ and prompts/, which up
  #   makes. A link is never followed: one could lead to this team's own state, or to / and give
  #   every seat Edit(//**) (sec on #197). check names the links it skips.
  # - listed: other_teams in the team file, for folders elsewhere (a pinned team's shared state,
  #   docs/pinned-release.md), with the roles of this team that observe that team: they may read
  #   its log and notes, as the owner approves (an observer scope), never its triage records.
  # Neither may be, hold or sit inside this team's own state folder (real paths), nor this team's own
  # work: an Edit deny there would stop the seats working. A listed folder that does not exist yet
  # passes the state-folder test below, so this one must also catch a future worktree (qa on #200).
  # macOS disks are normally case-insensitive and normalization-insensitive, and File.realpath keeps
  # the path as typed, so paths compare in NFC lower case there (tl and sec on #200); erring this way
  # refuses more.
  def path_overlap?(a, b)
    fold = RUBY_PLATFORM.include?('darwin') ? ->(x) { x.unicode_normalize(:nfc).downcase } : ->(x) { x }
    x = fold.call(real_path(a))
    y = fold.call(real_path(b))
    within = ->(i, o) { i == o || i.start_with?(o.end_with?('/') ? o : "#{o}/") }
    within.call(x, y) || within.call(y, x)
  end

  def overlaps_own_state?(path)
    path_overlap?(path, state_dir)
  end

  # How path overlaps this team's own work, or nil: it is, holds or sits inside the repository, the
  # worktree folder or a seat's working directory, or it is or holds the home folder or this factory
  # checkout. When the repository or a working directory holds this team's own state root (a team
  # working on software-factory keeps .state/ in its own checkout, tl on #200), a folder inside that
  # state root is exempt from "sits inside" it: the other teams' folders are there. So is a listed
  # folder that is a team's state folder in a factory checkout's .state (listed_team_state?, #205).
  def own_work_overlap(path, listed: false)
    fold = RUBY_PLATFORM.include?('darwin') ? ->(x) { x.unicode_normalize(:nfc).downcase } : ->(x) { x }
    within = ->(i, o) { i == o || i.start_with?(o.end_with?('/') ? o : "#{o}/") }
    r = fold.call(real_path(path))
    root = fold.call(real_path(File.dirname(state_dir)))
    holds = ->(dir) { within.call(fold.call(real_path(dir)), r) }
    in_root = r != root && within.call(r, root)
    team_dir = listed && listed_team_state?(path)
    meets = lambda do |dir|
      d = fold.call(real_path(dir))
      # Only a repository or workdir that holds the state root strictly: one that IS the state root
      # would exempt all of itself (sec on #200).
      team_dir || (in_root && root != d && within.call(root, d)) ? holds.call(dir) : path_overlap?(path, dir)
    end
    return "is, holds or sits inside this team's repository (repo.path)" if meets.call(repo_path)
    return "is, holds or sits inside this team's worktree folder (#{worktree_root})" if meets.call(worktree_root)

    roles.each_key { |id| return "is, holds or sits inside seat #{id}'s working directory" if meets.call(workdir(id)) }
    return 'is or holds the home folder' if holds.call(home_utf8)
    return 'is or holds this factory checkout' if holds.call(INSTALL)

    nil
  end

  # A listed folder that may sit inside this team's own work (#205): a team pinned to a release whose
  # repo.path is the factory checkout lists <factory>/.state/<team>, inside its repository. It must
  # exist, hold team state, and have a parent whose real name, links resolved, is exactly .state: the
  # factory's own git-ignored layout. A source folder that merely holds settings/, launch/ and
  # prompts/, or one under a link named .state, does not qualify, and neither does a missing or empty
  # folder (tl and sec on #204). File.realpath keeps the case as typed on a case-insensitive disk, so
  # the parent's name is also taken as stored on disk, from its own folder's listing: a folder named
  # .State on disk does not qualify however the entry spells it (tl on #223). A folder that can't be
  # listed fails closed.
  def listed_team_state?(path)
    return false unless File.directory?(path) && team_state?(path)

    parent = File.dirname(File.realpath(path))
    File.basename(parent) == '.state' && Dir.children(File.dirname(parent)).include?('.state')
  rescue SystemCallError
    false
  end

  # An existing folder with nothing in it but a lone .DS_Store (#204): that team has not run up yet.
  def empty_dir?(path)
    File.directory?(path) && (Dir.children(path) - ['.DS_Store']).empty?
  rescue SystemCallError
    false
  end

  def team_state?(path)
    STATE_MARKERS.all? { |m| File.directory?(File.join(path, m)) }
  end

  # [found, skipped]: other teams' folders found in the state root, and [path, why] for each link
  # passed over that leads to a team's state, or folder that overlaps this team's own.
  def other_teams_found
    @other_teams_found ||= begin
      root = File.dirname(state_dir)
      found = []
      skipped = []
      names = begin
        File.directory?(root) ? Dir.children(root).sort : []
      rescue SystemCallError => e
        skipped << [root, "could not be listed (#{e.class.name.split('::').last}): no other teams found there"]
        []
      end
      names.each do |name|
        p = File.join(root, name)
        next if p == state_dir

        if File.symlink?(p)
          if overlaps_own_state?(p)
            skipped << [p, "a symlink to this team's own state folder, or to a folder holding it"]
          elsif team_state?(p)
            skipped << [p, "a symlink: list it under other_teams if it is another team's state folder"]
          end
        elsif File.directory?(p) && team_state?(p)
          if overlaps_own_state?(p)
            skipped << [p, "it is this team's own state folder, holds it or sits inside it"]
          elsif (what = own_work_overlap(p))
            skipped << [p, "it #{what}"]
          else
            found << { 'path' => p, 'observers' => [], 'how' => 'found' }
          end
        end
      end
      [found, skipped]
    end
  end

  def other_teams_listed
    v = @c['other_teams']
    return [] if v.nil?

    die 'other_teams must be a list of { state, observers } entries' unless v.is_a?(Array)
    v.each_with_index.map do |e, i|
      die "other_teams entry #{i + 1} must be a mapping of state and observers" unless e.is_a?(Hash)
      bad = e.keys - OTHER_TEAM_KEYS
      die "unknown key(s) under 'other_teams' entry #{i + 1}: #{bad.join(', ')} (allowed: #{OTHER_TEAM_KEYS.join(', ')})" unless bad.empty?
      die "other_teams entry #{i + 1} needs state: the other team's state folder" unless e['state'].is_a?(String) && !e['state'].empty?
      p = expand(e['state'])
      obs = e['observers'] || []
      die "other_teams: observers of #{p} must be a list of role ids" unless obs.is_a?(Array) && obs.all? { |o| o.is_a?(String) }
      obs.each { |o| die "other_teams: observer #{o} of #{p} is not a role of this team" unless roles.key?(o) }
      die "other_teams: #{p} is this team's own state folder, holds it or sits inside it" if overlaps_own_state?(p)
      what = own_work_overlap(p, listed: true)
      die "other_teams: #{p} #{what}" if what
      # Only a team's state folder: a wrong entry such as ~, the volume or repo.path would deny this
      # team's own work, and a .state root one level too high would protect nothing while check said
      # it did (tl on #200). One that does not exist yet, or is still empty (that team has not run up,
      # #204), is accepted, and its denies apply once it does. A .state root that is empty now is
      # refused here as soon as any team starts under it, since it is then non-empty without team state.
      exists = File.exist?(p)
      empty = exists && empty_dir?(p)
      if exists && !empty && !team_state?(p)
        die "other_teams: #{p} is not a team's state folder (it holds no settings/, launch/ and prompts/): " \
            'name the folder itself, such as <checkout>/.state/<team>'
      end
      how = if !exists then 'listed; not found yet'
            elsif empty then "listed; empty, not a team's state yet"
            else 'listed'
            end
      { 'path' => p, 'observers' => obs, 'how' => how }
    end
  end

  # Found and listed together; a listed folder that was also found adds its observers to it.
  def other_teams
    @other_teams ||= other_teams_listed.each_with_object(other_teams_found[0].map(&:dup)) do |e, list|
      same = list.find { |t| real_path(t['path']) == real_path(e['path']) }
      if same
        same['observers'] |= e['observers']
      else
        list << e
      end
    end
  end

  # The denies on other teams' folders for seat id, in both spellings: Read on triage records always,
  # Read on the log and notes unless id observes that team, and Edit on all of it.
  def other_team_rules(id)
    other_teams.flat_map do |t|
      [File.expand_path(t['path']), real_path(t['path'])].uniq.flat_map do |sp|
        e = glob_escape(sp)
        rules = ["Read(/#{e}/triage/**)", "Edit(/#{e}/**)"]
        rules += ["Read(/#{e}/messages.log)", "Read(/#{e}/notes/**)"] unless t['observers'].include?(id)
        rules
      end
    end
  end

  # The Read deny on messages.log for a seat other than LOG_READER, in both spellings.
  def log_read_rules(id)
    return [] if id == LOG_READER

    log = File.join(state_dir, 'messages.log')
    [File.expand_path(log), real_path(log)].uniq.map { |p| "Read(/#{glob_escape(p)})" }
  end

  # A `permissions:` mapping (team level or a role's), checked. `where` names it in errors.
  def permission_section(h, where)
    return {} if h.nil?

    die "#{where} must be a mapping of deny, ask and allow lists" unless h.is_a?(Hash)
    bad = h.keys - PERMISSION_LISTS
    die "unknown key(s) under #{where}: #{bad.join(', ')} (allowed: #{PERMISSION_LISTS.join(', ')})" unless bad.empty?
    h.each do |list, rules|
      die "#{where}.#{list} must be a list of rules" unless rules.is_a?(Array)
      rules.each do |r|
        e = rule_error(r, list)
        die "#{where}.#{list}: invalid permission rule #{r.inspect}: #{e}" if e
      end
    end
    h
  end

  # The base branch without its remote (origin/main gives main), or nil when repo.base is not
  # <remote>/<branch>.
  def base_branch
    (repo['base'] || 'origin/main').to_s[%r{\A[^/]+/(.+)\z}, 1]
  end

  # Best effort, an early warning for a project whose base branch has no ruleset (the real control,
  # which makes this redundant where it exists): ask before any push whose destination is the base
  # branch, forced or not, since seats land changes through PRs. The character before the name (space, :, + or /) keeps a branch such as
  # "maintenance" from matching. Not caught: a bare `git push` while on the branch,
  # `git -C <dir> push`, a push from a script, or the GitHub API.
  def base_push_rules
    b = base_branch
    return [] if b.nil?

    [' ', ':', '+', '/'].flat_map { |c| ["Bash(git push *#{c}#{b})", "Bash(git push *#{c}#{b} *)"] }
  end

  # Patterns (escaped) for the files that change what a seat runs at its next start, or the rules it
  # runs under now: each path as configured and, when a symlink makes it differ, its real path too,
  # so neither spelling (nor the link itself) is left open. Every seat
  # gets an Edit deny on each (Edit also covers Write, NotebookEdit and shell redirects). This is not
  # a boundary: a script can still write them (see README, Safety, and #29).
  def protected_paths(id)
    [
      # what factory.sh regenerates for each start (settings, launchers, prompts) and the message log
      *(GENERATED_DIRS + HOOK_DIRS).map { |d| File.join(state_dir, d, '**') },
      File.join(state_dir, 'messages.log'),
      # the team file and the prompts it loads into every seat
      @path,
      *([prompts_common_path, prompts_project_path] + roles.values.map { |r| r['prompt'] && expand(r['prompt']) }).compact,
      # the launcher itself, and the wrapper it runs claude through
      File.join(INSTALL, 'factory.sh'), File.join(INSTALL, 'lib', '**'), File.join(INSTALL, 'roles', '**'),
      # the factory's plugin, which every seat loads at its next start
      File.join(PLUGIN_DIR, '**'),
      # and any plugin the team loads itself with --plugin-dir in args
      *args_plugin_paths(id),
      *wrapper_path,
      # settings a worktree session reads from the main checkout's root, and the skills, agents and
      # commands it reads from there when its own checkout lacks them. Not all of .claude/: Claude
      # Code makes its own worktrees in .claude/worktrees/, and seats must be able to edit them.
      File.join(repo_path, '.claude', 'settings.json'), File.join(repo_path, '.claude', 'settings.local.json'),
      *%w[skills agents commands].map { |d| File.join(repo_path, '.claude', d, '**') },
      # what else a session at repo.path loads from the main checkout at its next start: the project's
      # MCP servers (commands Claude Code starts), the hook scripts its settings call, and the
      # instructions kept under .claude/. Seats change these in their worktrees, never here.
      File.join(repo_path, '.mcp.json'), File.join(repo_path, '.claude', 'hooks', '**'),
      File.join(repo_path, '.claude', 'CLAUDE.md'), File.join(repo_path, '.claude', 'rules', '**'),
      # project settings load from the seat's own folder without a trust prompt, hooks included;
      # the rest of its .claude/ (commands, agents, skills) is ordinary project work
      File.join(workdir(id), '.claude', 'settings.json'), File.join(workdir(id), '.claude', 'settings.local.json'),
      # the user's own settings, MCP servers, instructions, rules and extensions (not all of ~/.claude,
      # where Claude Code's tools write legitimately), in every folder a session may load them from.
      # rules/: "Personal rules in ~/.claude/rules/ apply to every project on your machine"
      # (https://code.claude.com/docs/en/memory#user-level-rules); a live check on 2.1.316 showed them
      # loaded at session start from <CLAUDE_CONFIG_DIR>/rules/ too (#68).
      *claude_config_locations.flat_map do |claude_home, claude_json|
        [File.join(claude_home, 'settings.json'), claude_json, File.join(claude_home, 'CLAUDE.md'),
         *%w[plugins skills agents commands hooks rules].map { |d| File.join(claude_home, d, '**') }]
      end
    ].flat_map do |p|
      glob = p.end_with?('/**')
      base = glob ? p[0...-3] : p
      [File.expand_path(base), real_path(base)].uniq.map { |b| glob ? "#{glob_escape(b)}/**" : glob_escape(b) }
    end.uniq
  end

  # Each --plugin-dir in sessions.claude.args (`--plugin-dir X` or `--plugin-dir=X`): the .zip file, or
  # the folder with everything under it (whether or not it exists yet). claude runs in the seat's
  # folder, so a relative path is taken from there; a leading ~ is the home folder.
  def args_plugin_paths(id)
    a = args
    a.each_with_index.map do |x, i|
      v = if x == '--plugin-dir' then a[i + 1]
          elsif x.start_with?('--plugin-dir=') then x.split('=', 2)[1]
          end
      next if v.nil? || v.empty?

      p = File.expand_path(v.sub(/\A~(?=\/|\z)/, home_utf8), workdir(id))
      p.downcase.end_with?('.zip') ? p : File.join(p, '**')
    end.compact
  end

  # The wrapper claude runs through, if one is set. Inside an .app bundle the whole bundle is
  # protected: the program it runs can come from anywhere in the bundle (its Info.plist, other
  # executables, frameworks), so the executable alone would not be enough.
  def wrapper_path
    w = claude['wrapper']
    return [] if w.nil?

    w = expand(w)
    app = w[%r{\A(.*?\.app)/}, 1]
    [app ? File.join(app, '**') : w]
  end

  # Where Claude Code keeps the user's config: ~/.claude and ~/.claude.json, or, with
  # CLAUDE_CONFIG_DIR set, that folder and the .claude.json inside it ("every ~/.claude path lives
  # under that directory instead. The same applies to .claude.json":
  # https://code.claude.com/docs/en/claude-directory). Read from the environment factory.sh runs in;
  # each seat's launch script pins the same value (or unsets it), so a seat uses the folder its rules
  # protect, whatever the tmux server's own environment holds.
  def claude_config_paths
    dir = env_utf8('CLAUDE_CONFIG_DIR').to_s
    return [File.join(home_utf8, '.claude'), File.join(home_utf8, '.claude.json')] if dir.empty?

    dir = File.expand_path(dir.sub(/\A~(?=\/|\z)/, home_utf8))
    [dir, File.join(dir, '.claude.json')]
  end

  # Every config folder whose files must stay protected: the one seats use (claude_config_paths)
  # and, when CLAUDE_CONFIG_DIR moves it, the default ~/.claude and ~/.claude.json as well. The
  # owner's own sessions started without the variable (another terminal, the desktop app) still
  # load settings, hooks and MCP servers from the default folder.
  def claude_config_locations
    default = [File.join(home_utf8, '.claude'), File.join(home_utf8, '.claude.json')]
    [claude_config_paths, default].uniq
  end

  # The repository's auto-memory folder in every config folder (#108), as Edit-rule paths. Auto
  # memory lives in <config>/projects/<project>/memory/, one folder for the repository and every
  # worktree of it (https://code.claude.com/docs/en/memory#storage-location), named after the main
  # checkout's path: "non-alphanumeric characters replaced by -", and a name over 200 characters
  # cut to 200 with a hash of the full path appended
  # (https://code.claude.com/docs/en/sessions#where-transcripts-are-stored). The hash cannot be
  # computed here, so such a name is matched by its first 200 characters and a *. Both spellings
  # of the checkout's path (as configured and real) give a name, and both spellings of each config
  # folder are denied. A seat with auto memory off still has its file tools; this keeps them out
  # of the folder the owner's own sessions load at every start.
  def memory_paths
    names = [File.expand_path(repo_path), real_path(repo_path)].uniq.map do |p|
      n = p.gsub(/[^A-Za-z0-9]/, '-')
      n.length > 200 ? "#{n[0, 200]}*" : n
    end.uniq
    claude_config_locations.flat_map do |home, _|
      [File.expand_path(home), real_path(home)].uniq.flat_map do |h|
        names.map { |n| "#{glob_escape(File.join(h, 'projects'))}/#{n}/memory/**" }
      end
    end.uniq
  end

  def memory_rules(id)
    auto_memory?(id) ? [] : memory_paths.map { |p| "Edit(/#{p})" }
  end

  def prompts_common_path
    p = @c['prompts']
    p && p['common'] ? expand(p['common']) : nil
  end

  # Every rule for a seat as [rule, list, source]: the team's, then the role's, then the ones
  # factory.sh adds itself.
  def permission_entries(id)
    out = []
    add = lambda do |h, source|
      PERMISSION_LISTS.each { |list| (h[list] || []).each { |r| out << [r, list, source] } }
    end
    add.call(permission_section(@c['permissions'], 'permissions'), 'team')
    add.call(permission_section(role(id)['permissions'], "roles.#{id}.permissions"), "roles.#{id}")
    # The note is outside the seat's working directory, so writing it would prompt in a mode other
    # than bypass: the seat may edit its own note. Every other seat's note is denied, because the
    # session-start hook puts a note into its seat's context: a seat that could write another's would
    # have a lasting channel into it. Exact paths, both spellings, not notes/** (that would also
    # deny the seat's own note, since deny wins over allow).
    own = note_rules(id)
    others = (roles.keys - [id]).flat_map { |r| note_rules(r) }
    tri = triage_rules(id)
    deny = protected_paths(id).map { |p| "Edit(/#{p})" } + others + log_read_rules(id) + memory_rules(id) + tri['deny'] +
           other_team_rules(id)
    add.call({ 'deny' => deny, 'ask' => base_push_rules, 'allow' => own + tri['allow'] }, 'factory.sh')
    out
  end

  # The seat's merged deny, ask and allow lists. Merging only adds: a role cannot remove or weaken a
  # team rule. A role may make a team rule stronger (team ask, role deny); the weaker copy is dropped.
  # A rule that a stronger one at the same level or above makes useless is an error, since it would
  # silently do nothing: a team deny over a role ask, a team ask over a role allow, or the same rule
  # in two lists of one level.
  def merged_permissions(id)
    entries = permission_entries(id)
    rank = ->(list) { PERMISSION_LISTS.index(list) }
    above = ->(source) { source.start_with?('roles.') ? [source, 'team', 'factory.sh'] : ['team', 'factory.sh'] }
    entries.each do |rule, list, source|
      next if source == 'factory.sh'

      stronger = entries.find { |r, l, s| r == rule && rank.call(l) < rank.call(list) && above.call(source).include?(s) }
      next unless stronger

      die "permission rule #{rule.inspect} in #{source} #{list} has no effect: #{stronger[2]} #{stronger[1]} " \
          "has the same rule, and Claude Code checks #{stronger[1]} first"
    end
    PERMISSION_LISTS.map do |list|
      rules = entries.select { |r, l, _| l == list && entries.none? { |r2, l2, _| r2 == r && rank.call(l2) < rank.call(l) } }
      [list, rules.map(&:first).uniq]
    end.to_h
  end

  # The repo's pass/fail command, its time limit, and how many failed gates in a row send a seat
  # back before its stop goes through (see lib/stop_gate.sh).
  def gate
    repo['gate']&.to_s
  end

  # Run in a worktree up has just made, before its seat starts (#10): a fresh worktree has no
  # installed dependencies. repo.copy lists small git-ignored files (an .env, local config) copied
  # from the main checkout first, as Claude Code's own worktrees do with .worktreeinclude
  # (https://code.claude.com/docs/en/worktrees).
  def bootstrap
    repo['bootstrap']&.to_s
  end

  def copy_paths
    (repo['copy'] || []).map(&:to_s)
  end

  def gate_timeout
    (repo['gate_timeout'] || 600).to_i
  end

  def gate_max_blocks
    (repo['gate_max_blocks'] || 3).to_i
  end

  def gate_on_stop?(id)
    role(id)['gate_on_stop'] == true
  end

  # The Stop hook that runs the gate when a seat with gate_on_stop ends a turn with uncommitted
  # changes. Exec form (args): each argument reaches the script as written, with no shell quoting.
  # The hook's own timeout is a backstop; the script enforces the gate's.
  def stop_gate_hook(id)
    { 'type' => 'command', 'command' => File.join(INSTALL, 'lib', 'stop_gate.sh'),
      'args' => [state_dir, id, workdir(id), gate, gate_timeout.to_s, gate_max_blocks.to_s],
      'timeout' => gate_timeout + 30 }
  end

  # The SessionStart hook every seat gets (#5): it prints the seat's progress note, branch, recent
  # commits and uncommitted files, which Claude Code adds to the seat's context. No matcher, so it
  # runs for every source (startup, resume, clear, compact): after a compaction the note is shown again.
  def session_start_hook(id)
    { 'type' => 'command', 'command' => File.join(INSTALL, 'lib', 'session_start.sh'),
      'args' => [state_dir, id, workdir(id)], 'timeout' => 10 }
  end

  # The SendMessage hook every seat gets (#39): on PostToolUse and PostToolUseFailure, it appends the
  # message to messages.log as say does, so native seat-to-seat traffic lands in the same log. The
  # roster's session names map a recipient to its role. Exec form: no shell quoting. It never blocks
  # or alters the message (lib/log_message.sh), and 5s is a backstop: it normally takes milliseconds.
  def log_message_hook(id)
    { 'type' => 'command', 'command' => File.join(INSTALL, 'lib', 'log_message.sh'),
      'args' => [File.join(state_dir, 'messages.log'), id, *roles.keys.map { |r| "#{session(r)}=#{r}" }],
      'timeout' => 5 }
  end

  # A line for check when the user's own settings switch every hook off: seats without a gate then
  # get no session-start note. nil when hooks are on, or the file is missing or unreadable.
  def hooks_note
    path = File.join(claude_config_paths[0], 'settings.json')
    j = JSON.parse(File.read(path)) rescue nil
    return nil unless j.is_a?(Hash) && j['disableAllHooks'] == true

    off = roles.keys.reject { |r| gate_on_stop?(r) }
    who = off.empty? ? 'no seat gets' : "#{off.join(', ')} #{off.size == 1 ? 'gets' : 'get'}"
    "disableAllHooks is true in #{path}, so #{who} no session-start note and no SendMessage logging " \
      '(a gated seat turns hooks back on for its gate)'
  end

  # The seat's Claude Code settings, written to <state>/settings/<id>.json and passed with
  # --settings. Later features add their own top-level keys (hooks, for example) here.
  def settings(id)
    perms = merged_permissions(id).reject { |_, rules| rules.empty? }
    mode = permission_mode(id)
    # A seat started in another mode cannot be switched into bypass from inside the session.
    perms['disableBypassPermissionsMode'] = 'disable' if mode && mode != 'bypassPermissions'
    out = perms.empty? ? {} : { 'permissions' => perms }
    # Claude Code's auto-updater reinstalls its package under a running seat, and macOS then cannot
    # tell which process the seat's claude is, so its privacy grants (the worktree volume) stop
    # working until a restart (#50). The launch script exports this too; a value here also outranks
    # one in a project's .claude/settings.json. Update deliberately instead (README).
    out['env'] = { 'DISABLE_AUTOUPDATER' => '1' }
    unless auto_memory?(id)
      # Both documented switches (same page as #auto_memory?): --settings outranks user, project and
      # local settings, so a seat's /memory toggle or its .claude/settings.local.json cannot turn
      # it back on. The launch script exports the variable too.
      out['autoMemoryEnabled'] = false
      out['env']['CLAUDE_CODE_DISABLE_AUTO_MEMORY'] = '1'
    end
    out['hooks'] = { 'SessionStart' => [{ 'hooks' => [session_start_hook(id)] }] }
    %w[PostToolUse PostToolUseFailure].each { |e| out['hooks'][e] = [{ 'matcher' => 'SendMessage', 'hooks' => [log_message_hook(id)] }] }
    if gate_on_stop?(id)
      out['hooks']['Stop'] = [{ 'hooks' => [stop_gate_hook(id)] }]
      # --settings outranks project and local settings, so a disableAllHooks: true written in the
      # seat's .claude/ cannot switch the gate off. It also turns on the user's own hooks for this
      # seat if they had switched them all off in ~/.claude/settings.json. Only the gate, a safety
      # control, justifies that: the session-start note is a convenience, so a seat without a gate
      # keeps the owner's choice and goes without the note (check says so, see hooks_note).
      out['disableAllHooks'] = false
    end
    out
  end

  def permissions_report
    added_by = ->(e) { e[2] == 'factory.sh' }
    out = []
    # Other teams' state folders (#197): what was found and listed, and the links passed over.
    teams = other_teams.map do |t|
      obs = t['observers'].empty? ? '' : "; observers: #{t['observers'].join(', ')}"
      "#{t['path']} (#{t['how']}#{obs})"
    end
    out << "other teams: #{teams.empty? ? 'none' : teams.join(', ')}"
    other_teams_found[1].each { |p, why| out << "skipped   : #{p} (#{why})" }
    out << "permissions per seat (they add to the rules in ~/.claude/settings.json and the repo's .claude/ settings, which still apply):"
    roles.each_key do |id|
      merged = merged_permissions(id)
      factory = permission_entries(id).select(&added_by).map(&:first)
      mode = mode_label(id)
      out << "[#{id}] mode #{mode}"
      PERMISSION_LISTS.each do |list|
        own = merged[list] - factory
        out << format('    %-5s: %s', list, own.empty? ? '(none)' : own.join(', '))
      end
      notes = (roles.keys - [id]).flat_map { |r| note_rules(r) }
      others = other_team_rules(id)
      logs = log_read_rules(id)
      mem = memory_rules(id)
      tri = triage_rules(id)
      added = merged['deny'].count do |r|
        factory.include?(r) && !notes.include?(r) && !logs.include?(r) && !mem.include?(r) && !tri['deny'].include?(r) && !others.include?(r)
      end
      asks = merged['ask'].count { |r| factory.include?(r) }
      note = merged['allow'].any? { |r| factory.include?(r) } ? ', Edit allow on its own progress note and deny on the other seats\'' : ''
      memo = mem.empty? ? '' : ", Edit deny on the repository's auto-memory folder (#{mem.size} spellings)"
      log = (merged['deny'] & logs).empty? ? '' : ', Read deny on the message log'
      triage = if id == TRIAGE_WRITER then ', Edit and Read allow on the triage record folder'
               elsif id == LOG_READER then ', Read allow and Edit deny on the triage record folder'
               else ', Edit and Read deny on the triage record folder'
               end
      watched = other_teams.select { |t| t['observers'].include?(id) }.map { |t| t['path'] }
      teams = if other_teams.empty? then ''
              else
                ", Read and Edit deny on #{other_teams.size} other teams' state folders" +
                  (watched.empty? ? '' : " (observer of #{watched.join(', ')}: may read its log and notes)")
              end
      out << "    added: Edit deny on #{added} protected paths#{asks.positive? ? ", ask on #{asks} push-to-#{base_branch} patterns" : ''}#{note}#{memo}#{log}#{triage}#{teams}"
      out << '    note : allow rules have no effect in bypassPermissions' if mode.start_with?('bypassPermissions') && !(merged['allow'] - factory).empty?
      out << '    note : ask rules are refused in dontAsk mode, not asked' if mode == 'dontAsk' && !merged['ask'].empty?
    end
    out << "note: no base-branch push rules (repo.base '#{repo['base']}' is not <remote>/<branch>)" if base_branch.nil?
    out << "the full generated file: ruby #{File.join(INSTALL, 'lib', 'team_config.rb')} #{@path} settings <role>"
    out
  end

  # The class Claude Code puts a seat's session in when no crossSessionInbound applies and it
  # decides from the two sessions' modes whether to hold a message: "It groups sessions that bypass
  # permission prompts into one class, and every other session into the other. Plan mode counts as
  # bypassing in interactive terminal sessions with bypass permissions available, and auto,
  # acceptEdits, and dontAsk count as prompting"
  # (https://code.claude.com/docs/en/cross-session-messaging#control-inbound-messages).
  # A seat with a permission_mode other than bypassPermissions has bypass switched off by its
  # settings (disableBypassPermissionsMode, see #settings), so its plan mode prompts. A legacy
  # plan mode in args has bypass available only with --allow-dangerously-skip-permissions there.
  # 'bypass', 'prompting', or nil for a seat that inherits its mode from settings files check does
  # not read.
  def message_class(id)
    mode = permission_mode(id)
    available = mode == 'bypassPermissions'
    if mode.nil?
      label = mode_label(id)
      return nil if label == '(inherit)'

      mode = label.sub(/ \(args\)\z/, '')
      available = mode == 'bypassPermissions' || args.include?('--allow-dangerously-skip-permissions')
    end
    mode == 'bypassPermissions' || (mode == 'plan' && available) ? 'bypass' : 'prompting'
  end

  def may_merge?(id)
    role(id)['may_merge'] == true
  end

  # Whether a Bash permission rule matches every command a Bash pattern matches: the rule's `*`
  # matches anything, so it covers the pattern when it matches the pattern's text with the
  # pattern's own `*` taken literally. The legacy prefix form `cmd:*` is read as `cmd *`, space
  # included: "`Bash(ls:*)` matches the same commands as `Bash(ls *)`", and "The space before a
  # trailing `*` is part of the rule" (https://code.claude.com/docs/en/permissions). Read as `cmd*`,
  # Bash(gh pr mer:*) would wrongly count as covering `gh pr merge *`.
  def rule_covers?(rule, pattern)
    rule_matches?(rule, pattern[/\ABash\((.*)\)\z/m, 1].to_s)
  end

  # Whether a Bash rule matches one command's text, as the permissions docs describe it: `*` is any
  # text, `cmd:*` is `cmd *`, and a trailing ` *` that is the rule's only wildcard also matches the
  # bare command (`Bash(ls *)` matches `ls`). An approximation for `check` and tests: it does not
  # split compound commands, strip wrappers or VAR= prefixes, as Claude Code does.
  def rule_matches?(rule, command)
    return true if ['Bash', 'Bash(*)'].include?(rule)

    spec = rule[/\ABash\((.*)\)\z/m, 1]
    return false if spec.nil?

    spec = spec.sub(/:\*\z/, ' *')
    return true if spec.end_with?(' *') && spec.count('*') == 1 && command == spec[0...-2]

    re = Regexp.new("\\A#{spec.split('*', -1).map { |s| Regexp.escape(s) }.join('.*')}\\z", Regexp::MULTILINE)
    re.match?(command)
  end

  # The deny and ask rules of a seat that match a command, strongest first, as "<list> <rule>".
  def matching_rules(id, command)
    merged = merged_permissions(id)
    %w[deny ask].flat_map { |l| merged[l].select { |r| rule_matches?(r, command) }.map { |r| "#{l} #{r}" } }
  end

  # What `check` warns about. Warnings do not stop a start.
  def warnings
    held_message_warnings + merge_warnings + triage_warnings
  end

  # A role other than TRIAGE_WRITER that lists the security-triage skill would write its records
  # where its settings deny it (#138), so check says so before the seat meets the deny.
  def triage_warnings
    roles.keys.reject { |id| id == TRIAGE_WRITER }.select { |id| skills(id).any? { |n, _| n == 'factory:security-triage' } }.map do |id|
      "warning: #{id} lists factory:security-triage, but only a role with id #{TRIAGE_WRITER} may write triage " \
        "records (#{File.join(state_dir, TRIAGE_DIR)}/): every other seat may not write there."
    end
  end

  # Under the default inbound rule a message between the two classes is held in either direction:
  # a prompting receiver holds a message from a bypass sender, and a bypass receiver holds one from
  # any sender that is not bypassing (same page as #message_class). A held message waits at an
  # approval dialog in the receiver's pane and is dropped when the dialog expires.
  def held_message_warnings
    by = roles.keys.group_by { |id| message_class(id) }
    list = ->(ids) { ids.map { |id| "#{id} (#{mode_label(id)})" }.join(', ') }
    out = []
    if by['bypass'] && by['prompting']
      out << "warning: seat-to-seat messages will be held. Prompting for permissions: #{list.call(by['prompting'])}. " \
             "Bypassing them: #{list.call(by['bypass'])}."
      out << '  Messages from a bypass seat to a prompting seat, and from a prompting seat to a bypass seat, wait at an ' \
             "approval dialog in the receiver's pane and are dropped when it expires (dialogExpiry, 5 minutes by default). " \
             'Messages between seats of the same class are delivered.'
      out << '  Give every seat a permission_mode of the same class, or set crossSessionInbound (README: Which messages are held).'
    end
    if by[nil] && (by['bypass'] || by['prompting'])
      out << "note: check cannot see the permission mode of #{by[nil].join(', ')} (inherited from settings), so it " \
             'cannot tell whether messages between those seats and the others are held.'
    end
    out
  end

  def merge_warnings
    roles.keys.reject { |id| may_merge?(id) }.map do |id|
      merged = merged_permissions(id)
      guards = merged['deny'] + merged['ask']
      missing = MERGE_PATTERNS.reject { |p| guards.any? { |r| rule_covers?(r, p) } }
      next if missing.empty?

      "warning: #{id} could merge a PR without being asked: no deny or ask rule matches #{missing.join(', ')}. " \
        "Deny them in roles.#{id}.permissions, or set roles.#{id}.may_merge: true if #{id} is meant to merge."
    end.compact
  end

  def validate
    bad = @c.keys - TOP_KEYS
    die "unknown top-level key(s): #{bad.join(', ')} (allowed: #{TOP_KEYS.join(', ')})" unless bad.empty?
    die "'team' is required" unless @c['team'].is_a?(String) && @c['team'] =~ PREFIX_RE
    die "repo.path is required" unless repo['path']
    die "repo.github must be owner/name, e.g. acme/widgets" unless github =~ %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
    die "project.name is required" if project['name'].to_s.empty?
    die "project.url must be an https://github.com/ URL" unless project['url'].to_s.start_with?('https://github.com/')
    die "repo.path is not a directory: #{repo_path}" unless File.directory?(repo_path)
    other_teams_listed
    die 'storage.volume is required (an absolute path such as /Volumes/MyDrive)' unless storage['volume'].to_s.start_with?('/', '~')
    die 'storage.root is required and must be relative to the volume' if storage['root'].to_s.empty? || storage['root'].to_s.start_with?('/')
    die 'storage.root must not contain ..' if storage['root'].to_s.split('/').include?('..')
    die "sessions.prefix must match #{PREFIX_RE.source}" unless prefix =~ PREFIX_RE
    die 'display.iterm must be true or false' unless [true, false].include?(view_iterm)
    die "display.window must be 'full' or 'keep'" unless %w[full keep].include?(view_window)
    die "display.primary '#{view_primary}' is not a role id (roles: #{roles.keys.join(' ')})" unless roles.key?(view_primary)
    bad = claude.keys - CLAUDE_KEYS
    die "unknown key(s) under 'sessions.claude': #{bad.join(', ')}" unless bad.empty?
    die 'repo.gate must be a non-empty command' if repo.key?('gate') && !(repo['gate'].is_a?(String) && !repo['gate'].strip.empty?)
    die 'repo.bootstrap must be a non-empty command' if repo.key?('bootstrap') && !(repo['bootstrap'].is_a?(String) && !repo['bootstrap'].strip.empty?)
    if repo.key?('copy')
      die 'repo.copy must be a list of paths (relative to the main checkout)' unless repo['copy'].is_a?(Array)
      repo['copy'].each do |p|
        # Inside the main checkout only, and one path per line for factory.sh.
        ok = p.is_a?(String) && !p.empty? && !p.start_with?('/', '~') && !p.include?("\n") && !p.split('/').include?('..')
        die "repo.copy: '#{p}' must be a relative path inside the main checkout" unless ok
      end
    end
    %w[gate_timeout gate_max_blocks].each do |k|
      next unless repo.key?(k)

      what = k == 'gate_timeout' ? 'a positive whole number of seconds' : 'a positive whole number'
      die "repo.#{k} must be #{what}" unless repo[k].is_a?(Integer) && repo[k].positive?
    end
    die 'sessions.claude.plugin must be true or false' unless [true, false].include?(plugin?)
    if plugin? && !File.file?(File.join(PLUGIN_DIR, '.claude-plugin', 'plugin.json'))
      die "sessions.claude.plugin is on, but #{PLUGIN_DIR}/.claude-plugin/plugin.json is missing"
    end
    die 'sessions.claude.auto_memory must be true or false' if claude.key?('auto_memory') && ![true, false].include?(claude['auto_memory'])
    die "sessions.claude.effort must be one of #{EFFORTS.join(', ')}" if claude['effort'] && !EFFORTS.include?(claude['effort'].to_s)
    if claude.key?('permission_mode') && !PERMISSION_MODES.include?(claude['permission_mode'].to_s)
      die "sessions.claude.permission_mode must be one of #{PERMISSION_MODES.join(', ')}"
    end
    bad = (@c['prompts'] || {}).keys - PROMPT_KEYS
    die "unknown key(s) under 'prompts': #{bad.join(', ')}" unless bad.empty?
    die "'roles' must be a non-empty mapping" unless roles.is_a?(Hash) && !roles.empty?
    seen = {}
    roles.each do |id, r|
      die "role id '#{id}' must match #{ID_RE.source}" unless id.to_s =~ ID_RE
      die "role id 'launcher' is reserved: a seat's say messages would carry the kickoff's #{KICKOFF_LABEL} label" if id.to_s == 'launcher'
      die "role id 'owner' is reserved: a seat's say messages would carry the owner's [from owner] label" if id.to_s == 'owner'
      die "role '#{id}' must be a mapping" unless r.is_a?(Hash)
      bad = r.keys - ROLE_KEYS
      die "unknown key(s) under roles.#{id}: #{bad.join(', ')} (allowed: #{ROLE_KEYS.join(', ')})" unless bad.empty?
      die "roles.#{id}.title is required" if r['title'].to_s.empty?
      die "roles.#{id} needs exactly one of 'prompt' (a file) or 'prompt_text'" unless r.key?('prompt') ^ r.key?('prompt_text')
      w = r['workdir']
      die "roles.#{id}.workdir must be a mapping with a type" unless w.is_a?(Hash)
      bad = w.keys - WORKDIR_KEYS
      die "unknown key(s) under roles.#{id}.workdir: #{bad.join(', ')}" unless bad.empty?
      die "roles.#{id}.workdir.type must be 'project' or 'worktree'" unless %w[project worktree].include?(w['type'])
      die "roles.#{id}.workdir.path is required for type project" if w['type'] == 'project' && w['path'].to_s.empty?
      die "roles.#{id}.workdir.path is not allowed for type worktree (it is derived from storage)" if w['type'] == 'worktree' && w['path']
      if w['name'] && w['name'].to_s !~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
        die "roles.#{id}.workdir.name must be a plain folder name"
      end
      die "roles.#{id}.workdir.path is not a directory: #{workdir(id)}" if w['type'] == 'project' && !File.directory?(workdir(id))
      die "roles.#{id}.effort must be one of #{EFFORTS.join(', ')}" if r['effort'] && !EFFORTS.include?(r['effort'].to_s)
      die "roles.#{id}.model must be a non-empty string" if r.key?('model') && r['model'].to_s.strip.empty?
      die "roles.#{id}.gate_on_stop must be true or false" if r.key?('gate_on_stop') && ![true, false].include?(r['gate_on_stop'])
      die "roles.#{id}.gate_on_stop needs repo.gate (the command to run)" if r['gate_on_stop'] == true && gate.nil?
      validate_skills(id, r['skills']) if r.key?('skills')
      # A YAML boolean: the system ruby's YAML 1.1 also reads an unquoted yes or on as true.
      die "roles.#{id}.may_merge must be true or false" if r.key?('may_merge') && ![true, false].include?(r['may_merge'])
      die "roles.#{id}.auto_memory must be true or false" if r.key?('auto_memory') && ![true, false].include?(r['auto_memory'])
      if r.key?('permission_mode') && !PERMISSION_MODES.include?(r['permission_mode'].to_s)
        die "roles.#{id}.permission_mode must be one of #{PERMISSION_MODES.join(', ')}"
      end
      s = session(id)
      die "session name '#{s}' is used by both '#{seen[s]}' and '#{id}'" if seen[s]
      seen[s] = id
      role_prompt(id)
      kickoff(id)
    end
    prompts_common
    prompts_project
    roles.each_key { |id| render(id) } # unknown @@placeholders and a project label fail here, not at launch
    any_mode = claude.key?('permission_mode') || roles.values.any? { |r| r.key?('permission_mode') }
    args.each do |a|
      flag = a.split('=', 2).first
      when_reserved, why = RESERVED_FLAGS[flag]
      next if when_reserved.nil? || (when_reserved == :with_mode && !any_mode)

      die "sessions.claude.args: #{flag} is reserved: #{why}"
    end
    roles.each_key { |id| merged_permissions(id) } # bad rules and useless duplicates fail here
    true
  end
end

path, cmd, *args = ARGV
die 'usage: team_config.rb <team.yaml> <command> [args]' if path.nil? || cmd.nil?
cfg = TeamConfig.new(path)

case cmd
when 'validate' then cfg.validate
when 'ids' then puts cfg.roles.keys
when 'get'
  key = args.fetch(0) { die 'get needs a key' }
  case key
  when 'team' then puts cfg.instance_variable_get(:@c)['team']
  when 'repo.path' then puts cfg.repo_path
  when 'repo.github' then puts cfg.github
  when 'project.name' then puts cfg.project['name']
  when 'project.url' then puts cfg.project['url']
  when 'repo.base' then puts(cfg.repo['base'] || 'origin/main')
  when 'storage.volume' then puts cfg.volume
  when 'storage.root' then puts cfg.root
  when 'storage.worktree_root' then puts cfg.worktree_root
  when 'sessions.prefix' then puts cfg.prefix
  when 'display.iterm' then puts cfg.view_iterm
  when 'display.primary' then puts cfg.view_primary
  when 'display.window' then puts cfg.view_window
  when 'sessions.plugin' then puts(cfg.plugin? ? real_path(PLUGIN_DIR) : '')
  when 'sessions.wrapper' then puts(cfg.claude['wrapper'] ? cfg.expand(cfg.claude['wrapper']) : '')
  when 'state.dir' then puts cfg.state_dir
  when 'claude.config_dir' then puts cfg.claude_config_paths.first
  when 'state.generated_dirs' then puts GENERATED_DIRS
  when 'state.hook_dirs' then puts HOOK_DIRS
  when 'state.notes_dir' then puts File.join(cfg.state_dir, NOTES_DIR)
  when 'state.triage_dir' then puts(cfg.roles.key?(TRIAGE_WRITER) ? File.join(cfg.state_dir, TRIAGE_DIR) : '')
  when 'hooks.note' then puts cfg.hooks_note.to_s
  when 'prompts.summary' then puts cfg.prompts_summary
  when 'prompts.warning' then puts cfg.prompts_warning
  when 'repo.bootstrap' then puts(cfg.bootstrap || '')
  when 'repo.copy' then puts cfg.copy_paths
  when 'repo.gate_summary'
    puts(cfg.gate ? "#{cfg.gate} (timeout #{cfg.gate_timeout}s; a seat may stop after #{cfg.gate_max_blocks} failed gates in a row)" : 'none')
  else die "unknown key '#{key}'"
  end
when 'role'
  id, key = args
  case key
  when 'title' then puts cfg.title(id)
  when 'session' then puts cfg.session(id)
  when 'workdir_type' then puts cfg.workdir_type(id)
  when 'worktree_name' then puts cfg.worktree_name(id)
  when 'model' then puts(cfg.model(id) || '(inherit)')
  when 'effort' then puts(cfg.effort(id) || '(inherit)')
  when 'permission_mode' then puts cfg.mode_label(id)
  when 'gate' then puts(cfg.gate_on_stop?(id) ? 'on-stop' : '-')
  when 'auto_memory' then puts(cfg.auto_memory?(id) ? '(inherit)' : 'off')
  else die "unknown role key '#{key}'"
  end
when 'workdir' then puts cfg.workdir(args.fetch(0) { die 'workdir needs a role id' })
when 'claude_args' then puts cfg.claude_args(args.fetch(0) { die 'claude_args needs a role id' })
when 'render' then puts cfg.render(args.fetch(0) { die 'render needs a role id' })
when 'kickoff' then puts cfg.kickoff(args.fetch(0) { die 'kickoff needs a role id' })
when 'settings' then puts JSON.pretty_generate(cfg.settings(args.fetch(0) { die 'settings needs a role id' }))
when 'permissions_report' then puts cfg.permissions_report
when 'warnings' then puts cfg.warnings
when 'matching_rules' then puts cfg.matching_rules(args.fetch(0) { die 'matching_rules needs a role id' }, args.fetch(1) { die 'matching_rules needs a command' })
else die "unknown command '#{cmd}'"
end
