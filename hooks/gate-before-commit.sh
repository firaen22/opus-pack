#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher: Bash).
# Blocks `git commit` while the TARGET repo's ground-truth gates are red.
# Uses jq when available to parse the tool call JSON from stdin.
# Exit 0 = allow the tool call. Exit 2 = block it (stderr is fed back to the model).
# BLOCK/anomaly events append to ~/.claude/hooks/hooks.log for human audit.
#
# Two design points (both learned from real misfires):
# 1. The gates that run are the ones in the repo the commit TARGETS — resolved
#    from `git -C <dir>` or a preceding `cd <dir>` in the command — not the
#    session's $CLAUDE_PROJECT_DIR. A session open in project A must not gate a
#    commit to repo B with A's checks. $CLAUDE_PROJECT_DIR remains the fallback
#    for a bare `git commit` with no directory hints.
# 2. Commit DETECTION strips quoted strings and heredoc bodies first, so a
#    commit MESSAGE, a printf writing a script, or documentation prose that
#    merely mentions "git commit" cannot trip the gate. What remains is matched
#    as command structure: the word `git`, then `commit` before any command
#    separator. False positives that survive this merely run the gates (safe
#    direction); false negatives (e.g. a commit hidden inside `bash script.sh`)
#    are inherent to text-level hooks and out of scope.
set -u

log() {
  # Best-effort audit trail; logging failure must never affect the gate itself.
  { mkdir -p "$HOME/.claude/hooks" &&
    printf '%s gate-before-commit: %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" \
      >> "$HOME/.claude/hooks/hooks.log"; } 2>/dev/null || true
}

fallback_dir="${CLAUDE_PROJECT_DIR:-.}"

input=$(cat)

raw_looks_like_commit() {
  case "$input" in
    *git*commit*) return 0 ;;
    *) return 1 ;;
  esac
}

# Fail-closed paths: without a parsable command we can't resolve a target repo,
# so these fall back to gating on the session project dir, as before.
if command -v jq >/dev/null 2>&1; then
  if ! cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null); then
    if [ -f "$fallback_dir/checks/run-all.sh" ] && raw_looks_like_commit; then
      log 'BLOCK jq parse failed on a likely git commit'
      echo 'gate-before-commit hook: could not parse hook JSON for a likely git commit — blocking until fixed' >&2
      exit 2
    fi
    exit 0
  fi
else
  if [ -f "$fallback_dir/checks/run-all.sh" ] && raw_looks_like_commit; then
    log 'BLOCK jq missing on a likely git commit'
    echo 'gate-before-commit hook: jq is not installed — blocking likely git commit until jq is installed or the hook is removed' >&2
    exit 2
  fi
  exit 0
fi

# --- Commit detection on command structure, not raw text ------------------
# Strip single- and double-quoted segments (commit messages, printf payloads),
# then drop everything from the first heredoc marker on (its body is data).
stripped=$(printf '%s' "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')
case "$stripped" in
  *'<<'*) stripped=${stripped%%<<*} ;;
esac
# The word `git`, then `commit` with no command separator (; & |) between them.
printf '%s' "$stripped" |
  grep -Eq '(^|[^[:alnum:]_./-])git[[:space:]]([^;&|]*[^[:alnum:]_./-])?commit([^[:alnum:]_-]|$)' ||
  exit 0

# --- Resolve the repo the commit targets -----------------------------------
# Last `git -C <dir>` wins, else the last `cd <dir>`, else the session dir.
# Unquoted args are extracted from the STRIPPED text (so a commit message
# mentioning "git -C <dir>" can't poison this); quoted args must come from the
# raw command (stripping removed them), so each candidate is validated with -d
# before being trusted — a non-directory candidate falls through, not back.
try_dir() { # expand ~ and accept only an existing directory
  c=$1
  c=${c%\"}; c=${c#\"}
  case "$c" in "~") c="$HOME" ;; "~/"*) c="$HOME/${c#\~/}" ;; esac
  [ -n "$c" ] && [ -d "$c" ] && printf '%s' "$c"
}
last_match() { printf '%s' "$1" | grep -oE -- "$2" | tail -n 1 | sed -E "s/$3//"; }
dir=""
for cand in \
  "$(last_match "$stripped" '-C[[:space:]]+[^[:space:];&|]+'                    '^-C[[:space:]]+')" \
  "$(last_match "$cmd"      '-C[[:space:]]+"[^"]+"'                             '^-C[[:space:]]+')" \
  "$(last_match "$stripped" '(^|[;&|][[:space:]]*)cd[[:space:]]+[^[:space:];&|]+' '^.*cd[[:space:]]+')" \
  "$(last_match "$cmd"      '(^|[;&|][[:space:]]*)cd[[:space:]]+"[^"]+"'          '^.*cd[[:space:]]+')"
do
  dir=$(try_dir "$cand") && [ -n "$dir" ] && break
done
[ -n "${dir:-}" ] || dir="$fallback_dir"

# The gate lives at the target repo's root; fall back to the dir itself.
repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || repo="$dir"
gates="$repo/checks/run-all.sh"
[ -f "$gates" ] || exit 0 # target repo has no gates — nothing to enforce

if out=$(bash "$gates" 2>&1); then
  exit 0
fi
log "BLOCK gates red on git commit (repo: $repo)"
{
  echo 'GATES RED — commit blocked by PreToolUse hook. Fix the gates, then retry:'
  printf '%s\n' "$out" | tail -n 20
} >&2
exit 2
