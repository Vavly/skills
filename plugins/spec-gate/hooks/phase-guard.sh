#!/usr/bin/env bash
# phase-guard.sh — PreToolUse hook for the spec-driven workflow.
#
# Enforces "no code before spec" as a tool-level block rather than an
# instruction. PreToolUse hooks fire before the permission-mode check, in every
# mode including bypassPermissions, and a deny blocks the call regardless. That
# is what makes this a gate and not a suggestion.
#
# Prevention only. It is precise for Edit/Write/NotebookEdit, where the path is
# a structured field, and best-effort for Bash, where it has to read intent out
# of a command string. Completeness is not this layer's job — the Stop scan in
# review-gate.sh catches whatever gets through.
#
# Inactive unless .claude/.spec-phase exists, so it costs nothing on normal work.
#
# Install: .claude/hooks/phase-guard.sh  (chmod +x)

set -uo pipefail

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# --- JSON reading, without a hard jq dependency ------------------------------
# A missing parser used to make this hook exit 0 silently, i.e. fail open, which
# is worse than not having a gate at all. It now falls back to python3 and, if
# neither exists, fails CLOSED with a visible reason.
PARSER=""
command -v jq      >/dev/null 2>&1 && PARSER=jq
[ -z "$PARSER" ] && command -v python3 >/dev/null 2>&1 && PARSER=python3

json_get() {  # $1 = dotted path, e.g. tool_input.file_path
  case "$PARSER" in
    jq)      printf '%s' "$INPUT" | jq -r ".$1 // empty" 2>/dev/null ;;
    python3) printf '%s' "$INPUT" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, dict) and k in d: d = d[k]
    else: sys.exit(0)
if d is None: sys.exit(0)
print(str(d).lower() if isinstance(d, bool) else d)
' "$1" 2>/dev/null ;;
  esac
}

# Decisions are built with printf so that emitting one needs no parser at all.
# The reason is stripped of the characters that would break hand-built JSON: a
# path containing a double quote used to produce malformed JSON, which Claude
# Code treats as "no decision" — so the deny was silently dropped and the call
# proceeded. Sanitising here covers every call site at once.
decide() {  # $1 = allow|deny|ask, $2 = reason
  reason=$(printf '%s' "$2" | tr -d '"\\' | tr '\n\r\t' '   ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
  exit 0
}

deny() { decide deny "$1"; }


# `ask` forces a confirmation prompt instead of refusing outright. Used for the
# one checkpoint where in-band approval is proportionate — see the advance policy
# below. Note that a hook's `ask` is NOT documented to survive
# bypassPermissions, unlike a `deny` and unlike an explicit `ask` rule in
# settings; settings.json carries a matching ask rule to cover that mode.
ask() { decide ask "$1"; }

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(json_get cwd)}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

# The policy file is read before the "is anything armed here" check, because the
# answer to that question now lives in it — twice over. A tree with no state of
# its own may still be the wrong half of a split, and where the state file even
# IS is policy: it moved out of the working tree and under the git directory, so
# a guard that located it by hand would be a second copy of spec_gate_dir waiting
# to disagree with the real one.
#
# Failing closed when the policy is unreadable therefore cannot test for the
# state file first. It tests for a gate directory instead, which is the same
# question one level up and needs nothing from the file that is missing.
if [ ! -r "$HOOK_DIR/phase-policy.sh" ]; then
  for _g in "$PROJECT_DIR/.git/spec-gate/.spec-phase" "$PROJECT_DIR/.claude/.spec-phase"; do
    [ -f "$_g" ] && deny "phase-guard cannot read phase-policy.sh next to it in $HOOK_DIR. Failing closed rather than guessing at the policy."
  done
  exit 0
fi
# shellcheck source=phase-policy.sh
. "$HOOK_DIR/phase-policy.sh"

GATE_DIR="$(spec_gate_dir)"
STATE="$GATE_DIR/.spec-phase"

# No state HERE is not the same as no state. It also describes a session standing
# in a worktree while the task is armed next door, and that used to exit 0 — the
# gate silently absent in exactly the tree the work was happening in. Checked
# before the early exit, because the early exit is the bug.
#
# "No state here" has a third meaning, and it is the one that cost the most: the
# state moved, and this repository was mid-task when it did. That is not an
# inactive workflow, it is an armed one nothing can see — and exiting 0 on it
# hands back production writes at Phase 3 with the user still believing a gate is
# up. Asked before the split, because it is a question about THIS tree.
PHASE=""
SPLIT=""
LEGACY=0
if [ ! -f "$STATE" ]; then
  spec_legacy_armed && LEGACY=1
  if [ "$LEGACY" = 0 ]; then
    SPLIT=$(spec_foreign_state "$PROJECT_DIR")
    [ -n "$SPLIT" ] || exit 0        # workflow not active anywhere: nothing to enforce
  fi
fi

if [ -z "$PARSER" ]; then
  deny "phase-guard cannot read the tool call: neither jq nor python3 is on PATH. Failing closed. Install jq, or ask the user to run phase.sh off to disable the phase gate."
fi

# A corrupt state file used to fall through to exit 0, silently disabling the
# gate — the same fail-open bug as a missing parser. It now fails closed, with a
# reason that says how to recover.
# Authenticated before it is read. Every other state file treats "does not
# verify" as "is not there", because absent is the safe direction for all of
# them — a gate re-arms, a receipt has to be re-earned. This one is the
# exception, and it is the exception for the reason the rule exists: absent means
# NO WORKFLOW here, so treating a forged phase file as missing would hand the
# forger exactly what they wrote it for. It fails closed instead, the same way a
# corrupt phase value already does.
if [ -f "$STATE" ] && ! spec_mac_ok "$STATE"; then
  deny "phase-guard: $STATE does not authenticate. Every spec-gate state file carries a keyed hash of its own fields, and this one does not verify — so it was not written by phase.sh. A phase written by hand is production code unlocked with nothing asked, which is the whole of what this gate exists to prevent, so it is refused rather than believed. Recover with 'phase.sh off' and start the task again; if you did not edit it, the key under .git/ may have been replaced or removed."
fi

PHASE=$(sed -n 's/^phase=//p' "$STATE" 2>/dev/null | head -1)
case "$PHASE" in
  1|2|3|4|5) ;;
  "") { [ -n "$SPLIT" ] || [ "$LEGACY" = 1 ]; } \
        || deny "phase-guard: $STATE is unreadable. Failing closed." ;;
  *) deny "phase-guard: $STATE is corrupt (phase=$PHASE). Failing closed, because a broken state file must not silently disable the gate. Ask the user with 'phase.sh ask abandon', or repair the file." ;;
esac

# --- What would this Bash command write? -------------------------------------
# Parse the forms whose target is unambiguous. Refuse the write-ish forms whose
# target cannot be parsed, rather than allowing them.
#
# This reads a token stream rather than raw text: a `>` is an operator only where
# the shell would treat it as one, and a heredoc body is data. Asking "is there a
# > in this string?" refused a steady stream of commands that wrote nothing — a
# JS arrow function, a comparison inside a quoted jq or awk program, an arrow in
# a commit message, and any of those inside the heredoc that writes a plan
# document, which is work this workflow explicitly asks for.
#
# Written in awk rather than bash. Stepping through ${s:i:1} is O(n^2) on a long
# string: 20 KB of command took 15.3s against this hook's 15s timeout, on the
# bash 3.2 that /usr/bin/env bash resolves to on macOS. A hook that exceeds its
# timeout emits no decision, and no decision reads as no opinion — so the Bash
# gate vanished for exactly the commands most likely to be long: a git commit
# message, a gh pr body, a heredoc plan. awk is on every system that has bash,
# scans in one pass, and adds no dependency.
#
# One token per line: "OP<TAB>>", "OP<TAB>>>", "SEP", or "WORD<TAB><text>".
# Quotes are consumed rather than stripped afterwards, so a quoted redirect
# target survives as a single word: the target of `> "src/a b.ts"` is
# `src/a b.ts`, not the `"src/a` a regex would report.
#
# The single-quote character is built with sprintf rather than written, so the
# whole program sits inside a single-quoted shell string with nothing escaped.
#
# --- The work budget ---------------------------------------------------------
# How long this hook takes is a security property, not a performance one. A
# PreToolUse hook that gets killed emits no JSON, and no JSON reads as no
# decision — so the call proceeds. Anything the model can make arbitrarily slow
# is therefore an allow it can reach on demand, and both scanners were linear or
# worse in a word count it chooses: scan_state_tokens forked one awk per
# argument, and the segment walks below accumulate words into a string, which is
# quadratic. 6000 arguments took 20s against a 15s timeout.
#
# So the scan is bounded, and running out is a DENY rather than a slow allow.
# Two counters, because they bound different things: tokens caps the total work,
# lexes caps the number of forks a nested payload can demand. Both are global and
# shared across every recursion, or the bound is per-call and means nothing.
#
# The limits are far above real commands — a legitimate one is tens of tokens,
# not thousands — and heredoc bodies are consumed as data by the lexer, so a long
# journal entry or plan document costs one token, not one per word.
# Three axes, because the cost has three shapes and bounding one leaves the
# others: many tokens, many nested payloads (one fork each), and total bytes —
# `${t##*/}` is quadratic in bash 3.2, so ONE 130 KB token outran the timeout
# while the token count stood at 1.
#
# And a fourth axis, which is the only one that measures the thing actually being
# protected. The three counters above are proxies: they bound work in units that
# were *once* proportional to time, and every one of them has been outrun by an
# input that stayed under it and ran long anyway. 1000 assignments is half the
# token budget and took 120s; 1900 glob tokens is under it and took 22s. Against a
# 15s timeout both were a silent allow. Seconds are what the timeout is denominated
# in, so seconds are what has to be counted.
#
# SECONDS is elapsed time for this process, which is exactly the clock the host
# runs the 15s timeout on — so this is global rather than per-scan. A per-scan
# window would give each of the three top-level walkers its own 8s and total 24s,
# i.e. a bound that cannot fire before the thing it is bounding. The token, byte
# and lex counters stay per-scan and stay as they are: they are cheap early exits
# that catch the common shapes before any clock has to be read.
SCAN_TOKENS=0
SCAN_LEXES=0
SCAN_BYTES=0
SCAN_TOKEN_BUDGET=2000
SCAN_LEX_BUDGET=64
SCAN_BYTE_BUDGET=262144
SCAN_SECONDS_BUDGET=8
MAX_TOKEN_BYTES=65536
BASENAME_MAX=256
# One physical line of shell. The lexer builds words a character at a time, so
# this bounds the quadratic directly and is checked inside awk before the work
# is done. Heredoc BODY lines are exempt — they are read whole, never scanned
# character by character, which is why a long plan document stays cheap.
MAX_LINE_BYTES=65536
OVERSIZE_MSG="This command is too large for phase-guard to evaluate: it exceeds the scan budget, and a scan that cannot finish inside the hook timeout would emit no decision at all, which reads as permission. Refusing is the only safe answer. Split it into separate commands, or use Write/Edit for file changes so the target is a structured field instead of something to parse out of shell."

# Every one of these must be reached from the CURRENT shell. `deny` is
# printf-then-exit, so raised inside `$( )` the JSON lands in the captured
# string and the exit ends only the subshell — the hook then falls off the end
# having printed nothing, and no output reads as no decision. That is how the
# budget's own refusal became a fail-open: a command sized to survive the state
# scan and run out during the phase-call walk was allowed silently. So no
# scanner may be invoked inside a command substitution, and budget_lex is called
# at the call sites rather than inside lex_command, which is always `$(...)`.
budget_token() {
  [ "$SECONDS" -ge "$SCAN_SECONDS_BUDGET" ] && deny "$OVERSIZE_MSG"
  SCAN_TOKENS=$((SCAN_TOKENS + 1))
  [ "$SCAN_TOKENS" -gt "$SCAN_TOKEN_BUDGET" ] && deny "$OVERSIZE_MSG"
  SCAN_BYTES=$((SCAN_BYTES + ${#1}))
  [ "$SCAN_BYTES" -gt "$SCAN_BYTE_BUDGET" ] && deny "$OVERSIZE_MSG"
  [ "${#1}" -gt "$MAX_TOKEN_BYTES" ] && deny "$OVERSIZE_MSG"
  return 0
}
budget_lex() {
  [ "$SECONDS" -ge "$SCAN_SECONDS_BUDGET" ] && deny "$OVERSIZE_MSG"
  SCAN_LEXES=$((SCAN_LEXES + 1))
  [ "$SCAN_LEXES" -gt "$SCAN_LEX_BUDGET" ] && deny "$OVERSIZE_MSG"
  return 0
}

# Checked before the text is handed to the lexer, because the lexer is where the
# cost is. Every budget above counts tokens the lexer has already produced, so
# none of them can fire until the expensive part is over — which is how 700 KB
# in one word took 23s with the token count standing at 1.
budget_input() {
  [ "${#1}" -gt "$SCAN_BYTE_BUDGET" ] && deny "$OVERSIZE_MSG"
  return 0
}

# Each top-level scan gets its own allowance; recursion inside one shares it.
# A single counter across all of them meant an ordinary command could spend the
# state scan's budget and leave the phase-call walk to run out — which is how a
# thousand harmless words in front of a transition became an allow. Total work
# stays bounded either way, since every scan is bounded on its own.
budget_reset() {
  SCAN_TOKENS=0
  SCAN_BYTES=0
  SCAN_LEXES=0
  return 0
}

# Basename extraction, but never on a token long enough for `##` to be the whole
# cost of the scan. Nothing that long is a command name, so the full token is
# handed back and simply matches no verb.
tok_base() {   # sets TB
  if [ "${#1}" -gt "$BASENAME_MAX" ]; then TB=$1; else TB=${1##*/}; fi
}

lex_command() {
  printf '%s' "$1" | awk -v MAXLINE="$MAX_LINE_BYTES" '
    BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34); BS = sprintf("%c", 92)
            HDM = sprintf("%c", 1) "HD"
            hd_head = 1 }   # awk zero-inits, and hd_d[0] is a delimiter that never matches
    # Output is buffered from the moment a heredoc is registered until its body
    # has been consumed, then replayed after it. Without that, an operator later
    # on the same line closed the segment before the body arrived — `bash <<EOF |
    # cat` handed the body to `cat`, and a body whose verb looks harmless is
    # discarded as prose. Holding only the end-of-line SEP was not enough,
    # because `|` and `&&` end a segment too.
    function out(s) {
      if (defer) buf = buf s "\n"; else print s
    }
    # Each heredoc registration leaves a numbered placeholder where the `<<`
    # appeared, and the body is spliced back in at that exact position once it
    # has been read. Holding the separators alone was not enough: one line can
    # open two heredocs for two different verbs, and `cat <<A && bash <<B` has no
    # single position where an untagged body is correct — every body ended up
    # attributed to the first verb, so the second one was dropped whole.
    function flushbuf(   m, i2, l, k) {
      m = split(buf, ln, "\n")
      for (i2 = 1; i2 <= m; i2++) {
        l = ln[i2]
        if (l == "") continue
        if (substr(l, 1, length(HDM)) == HDM) {
          k = substr(l, length(HDM) + 1) + 0
          if (k in body) printf "%s", body[k]
        } else print l
      }
      buf = ""; defer = 0
    }
    function flush() {
      if (have) out("WORD\t" w)
      w = ""; have = 0
    }
    function nexthd() {
      if (hd_head <= hd_tail) {
        hd_active = 1; hd_delim = hd_d[hd_head]; hd_strip = hd_s[hd_head]
        hd_cur = hd_id[hd_head]; hd_head++
      } else hd_active = 0
    }
    {
      # A heredoc body is data *to the lexer* — nothing in it is tokenised as
      # shell. But whether it is data at all depends on the verb: prose into
      # `phase.sh journal` is data, a script into `bash` or `python3` is the
      # program. So the body is emitted as HBODY rather than discarded, and the
      # caller decides based on the verb it already knows. Discarding it made an
      # interpreter reading stdin a channel this scanner looked away from.
      # (No apostrophes in here: this whole program is one single-quoted string.)
      if (hd_active) {
        t = $0
        if (hd_strip) sub(/^\t+/, "", t)
        if (t == hd_delim) {
          nexthd()
          if (!hd_active) flushbuf()
        } else body[hd_cur] = body[hd_cur] "HBODY\t" t "\n"
        next
      }
      # Each word is built one character at a time, which is quadratic, so a
      # single enormous word is the whole cost of the scan and it is paid here,
      # before any counter on the bash side can move. 700 KB in one word took
      # 23s against a 15s timeout, and a killed hook emits no decision at all.
      # Refusing on length is the only check that can run before the work does.
      if (MAXLINE > 0 && length($0) > MAXLINE) { print "OVER"; exit }
      line = $0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (q == 1) { if (c == SQ) q = 0; else w = w c; i++; continue }
        if (q == 2) {
          if (c == BS && i < n) { w = w substr(line, i+1, 1); i += 2; continue }
          if (c == DQ) q = 0; else w = w c
          i++; continue
        }
        if (c == SQ) { q = 1; have = 1; i++; continue }
        if (c == DQ) { q = 2; have = 1; i++; continue }
        if (c == BS) {
          # A backslash at end of line continues the logical line. Copying the
          # character past the end emitted an empty WORD that swallowed the
          # pending redirect, and the newline then ended the segment — so the
          # target on the next line was filed as an ordinary argument.
          if (i >= n) { cont = 1; i += 2; continue }
          w = w substr(line, i+1, 1); have = 1; i += 2; continue
        }
        if (c == " " || c == "\t") { flush(); i++; continue }
        # A `#` starting a word begins a comment; the rest of the line is not
        # shell. Without this an apostrophe in a comment opened a quote that
        # never closed, and every later line was absorbed into it.
        if (c == "#" && !have) break
        if (c == "<") {
          flush()
          # `<<<` is a herestring: the word after it is the text fed to the
          # command as stdin. Treated as a separator, that text became an
          # ordinary word opening a new segment, never re-read as shell and
          # never seen as stdin — so `bash <<< script` was a blind spot with
          # neither a redirect nor a pipe for the stdin check to notice.
          if (substr(line, i+1, 2) == "<<") { out("OPHERE"); i += 3; continue }
          if (substr(line, i+1, 1) == "<") {
            i += 2; strip = 0
            if (substr(line, i, 1) == "-") { strip = 1; i++ }
            while (i <= n && (substr(line, i, 1) == " " || substr(line, i, 1) == "\t")) i++
            d = ""
            while (i <= n) {
              c = substr(line, i, 1)
              if (c == " " || c == "\t" || c == ";" || c == "|" || c == "&" || c == ">" || c == "<") break
              if (c == SQ || c == DQ) {
                qc = c; i++
                while (i <= n && substr(line, i, 1) != qc) { d = d substr(line, i, 1); i++ }
                i++
              } else { d = d c; i++ }
            }
            # `$((1<<3))` is an arithmetic shift, not a heredoc. Its "delimiter"
            # parses as `3))`, which no line ever matches, so the rest of the
            # command was swallowed as body and nothing in it was scanned.
            if (d != "" && d !~ /[()$]/) {
              hd_tail++; hd_d[hd_tail] = d; hd_s[hd_tail] = strip
              hd_id[hd_tail] = ++hd_n
              defer = 1
              out(HDM hd_n)
            }
            continue
          }
          # A plain input redirect writes nothing, but it decides what a shell
          # RUNS: `bash -s < script` never names the script anywhere the scanner
          # can see. Emitted so the caller can refuse the combination.
          out("OPIN")
          i++; continue
        }
        if (c == ">") {
          flush()
          i++; op = ">"
          if (substr(line, i, 1) == ">") { op = ">>"; i++ }
          if (substr(line, i, 1) == "|") i++  # >| overrides noclobber, still a redirect
          if (substr(line, i, 1) == "&") {
            # >&2 and 2>&1 duplicate a descriptor. `>&word` where word is NOT a
            # descriptor is bash for `&>word` — a real write to a real file.
            rest = substr(line, i)
            if (rest ~ /^&[0-9]+/ || rest ~ /^&-/) {
              i++
              while (i <= n && substr(line, i, 1) ~ /[0-9-]/) i++
              continue
            }
            i++
          }
          out("OP\t" op); continue
        }
        # A pipe ends a segment like `;` does, but it also decides where stdin
        # for the NEXT segment comes from — `cat script | bash -s` runs a script
        # nothing in the token stream names. Marked so the caller can tell the
        # two apart; readers that only match KIND=SEP are unaffected.
        if (c == "|") { flush(); out("SEP\tpipe"); i++; continue }
        if (c == ";" || c == "&") { flush(); out("SEP"); i++; continue }
        w = w c; have = 1; i++
      }
      if (cont) { cont = 0; next }             # continued line: same word, same segment
      if (q != 0) { w = w " "; next }         # a quoted string spanning lines
      flush()
      out("SEP")
      if (!hd_active) nexthd()
    }
    # An unterminated heredoc leaves the buffer unflushed; emit it rather than
    # dropping the segment on the floor.
    END { flush(); if (buf != "") flushbuf() }
  '
}

# --- One lex, three walks ----------------------------------------------------
# Three walkers read the same token stream and each used to produce it for
# itself: `<<< "$(lex_command "$1")"` in scan_command, in scan_state_tokens and
# in phase_walk, which is three awk processes and three command substitutions for
# one command string — and the same again for every nested payload, since two of
# the three recurse into `-c` bodies independently.
#
# The stream cannot differ between them: it is a pure function of the text. So it
# is produced once and replayed. Bounded, because the cache holds whole token
# streams and a payload may be large; past the limit it simply re-lexes, which is
# today's behaviour rather than a failure.
#
# Safe under recursion without any care being taken: `<<< "$LEXOUT"` snapshots
# the value into a temp file before the loop begins, so a recursive call that
# refills the cache cannot move the stream an outer loop is walking. The callers
# take a local copy anyway, because relying on that is relying on a detail.
LEX_KEYS=()
LEX_VALS=()
LEX_CACHE_MAX=32
LEX_KEY_MAX=8192

lex_cached() {   # sets LEXOUT
  local i=0
  if [ "${#1}" -le "$LEX_KEY_MAX" ]; then
    while [ "$i" -lt "${#LEX_KEYS[@]}" ]; do
      if [ "${LEX_KEYS[$i]}" = "$1" ]; then LEXOUT=${LEX_VALS[$i]}; return 0; fi
      i=$((i + 1))
    done
  fi
  LEXOUT=$(lex_command "$1")
  if [ "${#1}" -le "$LEX_KEY_MAX" ] && [ "${#LEX_KEYS[@]}" -lt "$LEX_CACHE_MAX" ]; then
    LEX_KEYS+=("$1")
    LEX_VALS+=("$LEXOUT")
  fi
  return 0
}

# --- One definition of "what is this segment running" ------------------------
# The three walkers each carried their own copy of this, and the copies had
# drifted. finish_segment knew that `-exec` introduces a command; scan_state_tokens
# did not, so `find . -name '*.log' -exec rm -rf .claude {} \;` had VERB=find and
# the destructive-verb case never ran. phase_walk's dispatcher list omitted
# `xargs` because it handles it separately, and finish_segment's skip list had
# `{}`, `;` and `+` while the others did not.
#
# None of those differences was a decision. They are three transcriptions of one
# rule, and a rule transcribed three times is a rule that will be wrong in one of
# them — which is the whole finding, not the individual miss it produced. Asked
# in one place now, so the next divergence has nowhere to happen.

# A prefix standing in front of the real command: `sudo rm`, `env FOO=1 rm`,
# `xargs rm`. The verb is further along.
tok_is_dispatch() {
  case "$1" in
    sudo|env|command|nohup|time|xargs|exec) return 0 ;;
  esac
  return 1
}

# Introduces a NEW command whose own verb follows: find's three action
# predicates. Everything after one belongs to that command, not to find.
tok_opens_command() {
  case "$1" in
    -exec|-execdir|-ok|-okdir) return 0 ;;
  esac
  return 1
}

# Skippable while still looking for a verb: flags, and find's argument-list
# punctuation.
tok_skip_before_verb() {
  case "$1" in
    -*|'{}'|';'|'+') return 0 ;;
  esac
  return 1
}

# In-place editors: the target is genuinely ambiguous to parse (BSD `sed -i ''`
# versus GNU `sed -i`, script arguments that look like paths). Denying is the
# honest answer, and Edit is the better tool anyway.
#
# Matched on the segment's VERB, or on the word after a dispatcher that runs one
# (`xargs sed -i`, `find . -exec sed -i`). Matching every word turned
# `pytest tests/ex -s`, `bin/ex -s` and `cat notes/patch` into denials, because a
# path whose basename happens to be `ex` or `patch` is not a command.
finish_segment() {
  local seg=$SEGW hdoc=$SEGH t verb='' last='' ed='' ipe='' expect_verb=1 payload=''
  SEGW=''
  SEGH=''
  [ -z "$seg" ] && return 0
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    tok_base "$t"
    if [ "$expect_verb" = 1 ]; then
      case "$TB" in *=*) continue ;; esac
      tok_is_dispatch "$TB" && continue
      tok_skip_before_verb "$TB" && continue
      verb=$TB
      case "$TB" in
        sed|perl|awk) ed=$TB ;;
      esac
      case "$t" in
        ex)    ed=ex ;;
        patch) ipe=patch ;;
      esac
      expect_verb=0
      continue
    fi
    tok_opens_command "$t" && { expect_verb=1; continue; }
    case "$TB" in
      sed|perl|awk) ed=$TB; continue ;;
    esac
    case "$ed" in
      sed|perl) case "$t" in -i|-i[!-]*|-[!-]*i*|--in-place*) ipe=$ed ;; esac ;;
      ex)       case "$t" in -s|-[!-]*s*) ipe=ex ;; esac ;;
      awk)      case "$t" in -i|--in-place*|inplace) ipe=awk ;; esac ;;
    esac
    # awk writes files with a redirect to a quoted literal inside its program.
    # `$1 > 5` is a comparison and stays allowed; the quoted target tells them
    # apart.
    if [ "$verb" = awk ]; then
      case "$t" in
        *'>'*'"'*)
          AWKT=$(printf '%s' "$t" | sed -n 's/.*>>*[[:space:]]*"\([^"]*\)".*/\1/p')
          [ -n "$AWKT" ] && CAND="$CAND$AWKT"$'\n' ;;
      esac
    fi
    # A quoted string handed to a shell is not data, it is shell. Re-read it.
    case "$verb" in
      sh|bash|zsh|ksh|dash|eval)
        case "$t" in
          -*) ;;
          *)  payload="$payload $t" ;;
        esac ;;
    esac
    case "$verb" in
      tee|touch)              case "$t" in -*) ;; *) CAND="$CAND$t"$'\n' ;; esac ;;
      cp|mv|install|ln|rsync) case "$t" in -*) ;; *) last=$t ;; esac ;;
      dd)                     case "$t" in of=*) CAND="$CAND${t#of=}"$'\n' ;; esac ;;
    esac
  done <<< "$seg"
  [ -n "$last" ] && CAND="$CAND$last"$'\n'
  [ -n "${payload# }" ] && NESTED="$NESTED${payload# }"$'\n'
  # A heredoc body handed to a shell is the script it runs, so it is queued for
  # re-scanning exactly like a -c payload. Under any other verb it is data.
  if [ -n "$hdoc" ]; then
    case "$verb" in
      sh|bash|zsh|ksh|dash|eval) NESTED="$NESTED$hdoc"$'\n' ;;
    esac
  fi
  [ -n "$ipe" ] && deny "spec-driven: in-place editing (sed -i, perl -i, patch, awk -i inplace) is blocked because phase-guard cannot reliably tell which file it targets. Use Edit instead — the gate can evaluate that exactly."
  return 0
}

scan_command() {
  local KIND VAL _toks
  budget_input "$1"
  [ "${SCAN_DEPTH:-0}" = 0 ] && budget_reset
  budget_lex
  lex_cached "$1"; _toks=$LEXOUT
  WANT_TARGET=0
  SEGW=''
  SEGH=''
  while IFS=$'\t' read -r KIND VAL; do
    case "$KIND" in
      OVER) deny "$OVERSIZE_MSG" ;;
      OP)   WANT_TARGET=1 ;;
      SEP)  finish_segment; WANT_TARGET=0 ;;
      # The write scan is a third reader of the same token stream, and it was
      # never taught about heredoc bodies — so `bash <<EOF / echo pwned >
      # src/x.ts / EOF` wrote production code during the tests-only phase with
      # the guard emitting nothing, while `bash -c` with the same payload was
      # refused. A body under a shell verb is a nested payload like any other.
      # Not budgeted here: whether this body is a program or prose is not known
      # until the verb is, at the end of the segment. Charging it as tokens up
      # front refused a 3000-line journal entry, which is prose the workflow
      # asks for. A body that turns out to be a program is queued into NESTED
      # and scanned there, where it is budgeted like any other payload; the
      # total is bounded by budget_input either way.
      HBODY) SEGH="$SEGH$VAL"$'\n' ;;
      WORD)
        budget_token "$VAL"
        if [ "$WANT_TARGET" = 1 ]; then
          CAND="$CAND$VAL"$'\n'
          WANT_TARGET=0
        else
          SEGW="$SEGW$VAL"$'\n'
        fi ;;
    esac
  done <<< "$_toks"
  finish_segment
}

# `bash -c "echo x > src/y.ts"` is the obvious way around a scanner that treats a
# quoted string as inert. Each payload is re-tokenised as the shell it is, to a
# bounded depth so pathological nesting cannot spin.
collect_write_targets() {
  CAND=""
  NESTED=""
  local depth=0 queue payload
  # Its own allowance, like the other two top-level scanners. Without this the
  # write scan started from whatever the phase walk had already spent, which
  # silently halved it.
  SCAN_DEPTH=0
  scan_command "$1"
  SCAN_DEPTH=1
  while [ -n "$NESTED" ] && [ "$depth" -lt 4 ]; do
    queue=$NESTED; NESTED=""
    depth=$((depth + 1))
    while IFS= read -r payload; do
      [ -n "$payload" ] && scan_command "$payload"
    done <<< "$queue"
  done
}

TOOL=$(json_get tool_name)
CMD=""
PATHS=""
case "$TOOL" in
  Edit|Write|NotebookEdit) PATHS=$(json_get tool_input.file_path) ;;
  Bash)                    CMD=$(json_get tool_input.command) ;;
  *) exit 0 ;;
esac

if [ -n "$CMD" ] && ! awk 'BEGIN{exit 0}' </dev/null >/dev/null 2>&1; then
  deny "phase-guard cannot read the command: awk is missing or not working, and the Bash write scan is written in it. Failing closed, because a scan that cannot run must not read as permission. Install awk, or ask the user to run phase.sh off to disable the phase gate."
fi

# --- A task recorded in the previous layout ----------------------------------
# There is no phase here to enforce, because the file holding it is one this
# version does not read. What there is, is evidence that a task was open when the
# state moved — so the one thing this must not do is what it did before the check
# existed, which is conclude "inactive" and hand back every write the phase was
# refusing.
#
# Refusing the WRITES rather than the tree, for the same reason the split does:
# `phase.sh status` has to report this, `phase.sh migrate` has to be able to fix
# it, and `phase.sh off` has to be able to end it. A denial that also blocks its
# own recovery is not a denial, it is a brick.
if [ "$LEGACY" = 1 ]; then
  case "$TOOL" in
    Edit|Write|NotebookEdit) deny "$SPEC_LEGACY_MSG" ;;
    Bash)
      collect_write_targets "$CMD"
      while IFS= read -r P; do
        [ -z "$P" ] && continue
        in_project "$P" && deny "$SPEC_LEGACY_MSG"
      done <<< "$CAND"
      ;;
  esac
  exit 0
fi

# --- A task armed in another worktree ----------------------------------------
# There is no local phase to enforce, so the only question is whether this call
# would write into a tree the armed gate cannot judge.
#
# Failing closed means refusing the WRITES, not bricking the tree. Denying before
# the tool was even looked at killed `ls`, `git status` and `cat` — and the
# `phase.sh status` that reports the split, which left the one escape hatch
# unreachable from the session that needed it. It also caught Claude Code's own
# worktree-isolated subagents, which is most of when this fires at all.
if [ -n "$SPLIT" ]; then
  SPLIT_MSG=$(spec_split_message "$SPLIT" "$(spec_realpath "$PROJECT_DIR")")
  case "$TOOL" in
    Edit|Write|NotebookEdit) deny "$SPLIT_MSG" ;;
    Bash)
      # No special case for phase.sh. Matching the name — as a substring or even
      # anchored as a word — let `echo x > src/x.ts # phase.sh` and
      # `cat .claude/hooks/phase.sh > src/x.ts` skip the check, because naming a
      # command is not running it. What actually matters is whether this call
      # writes anything: `phase.sh status` writes nothing the scanner can see, so
      # it passes on its own merits, and phase.sh refuses across a split by
      # itself anyway.
      collect_write_targets "$CMD"
      while IFS= read -r P; do
        [ -z "$P" ] && continue
        in_project "$P" && deny "$SPLIT_MSG"
        case "$P" in
          /*) PN=$(spec_norm_path "$P")
              while IFS= read -r WTREE; do
                [ -n "$WTREE" ] || continue
                WTREE=$(spec_realpath "$WTREE")
                [ -n "$WTREE" ] || continue
                case "$PN" in "$WTREE"/*) deny "$SPLIT_MSG" ;; esac
              done <<< "$(spec_worktrees "$PROJECT_DIR")" ;;
        esac
      done <<< "$CAND"
      ;;
  esac
  exit 0
fi

# --- Phase state is off limits, in every phase -------------------------------
# Checked before the phase>=4 early exit below. Otherwise at Phase 5 the model
# could write phase=4 and suppress the review gate, and at any phase it could
# `rm` the state file to unlock production writes.
#
# This used to conclude on a substring of the raw command, and the raw command
# is not what the shell runs. Every one of these was ALLOW:
#
#   printf x > .claude/.spec-vali''dation   same inode, no `.spec-validation`
#   rm -f .claude/.spec-*                   names nothing until the glob expands
#   git clean -fdx                          names nothing, removes all of them
#   rm -rf .claude                          takes the directory instead
#
# The first is the 4 -> 5 marker at the only phase it exists in; the last two
# sweep the whole gate away with no evasion in them at all. Concluding on text
# also denied a journal entry for *describing* a state file, because a substring
# cannot tell shell from a heredoc body — the same mistake in the other
# direction. So the tokens the shell would actually produce are what decides
# now, and a phase-state hit is denied wherever it appears, in any verb.
#
# Deliberately not gated behind a cheap `case "$CMD"` pre-filter. That is one
# more list of spellings to be incomplete, which is the bug being fixed; one awk
# pass on a command line is cheaper than the class of hole it closes.
# STATE_DIR_REL comes from phase-policy.sh, which all three layers source. It is
# defaulted here so this file still parses standalone if the policy is missing —
# the same degradation the other shared names get.
: "${STATE_DIR_REL:=.claude}"

# The gate directory as this project would name it. Empty when it is not inside
# the project at all — a linked worktree keeps its state under the main
# checkout's .git/worktrees/<name>, which no relative token from here can reach.
GATE_DIR_REL="$(spec_gate_dir_rel)"

# True when a path, once normalised, is the directory holding the state files or
# an ancestor of it. `rm -rf .` and `rm -rf .git` remove every state file without
# naming one.
#
# The state lives under the git directory now, so the ancestor chain this has to
# walk is `.git/spec-gate`, `.git`, `.` — not `.claude`. That is the whole point
# of the move: `.claude` is a directory the model legitimately writes, so every
# rule about it had to carve out the parts that are fine, and the carve-outs were
# where the holes kept appearing. Nothing legitimate removes `.git`.
covers_state_dir() {
  local p=$1 d
  p=${p%/}; p=${p#./}
  [ -z "$p" ] && return 0
  case "$p" in
    .|..) return 0 ;;
  esac
  d=$GATE_DIR_REL
  while [ -n "$d" ] && [ "$d" != . ] && [ "$d" != / ]; do
    [ "$p" = "$d" ] && return 0
    case "$d" in */*) d=${d%/*} ;; *) d='' ;; esac
  done
  case "$p" in
    /*) case "$(spec_gate_dir)" in
          "$p"|"$p"/*) return 0 ;;
        esac ;;
  esac
  return 1
}

# --- The fixed lists, resolved once ------------------------------------------
# Everything below used to recompute these per TOKEN: glob_hits_state forked
# `$(spec_state_list)` twice per glob, glob_hits_state_base once more, and
# names_gate_key forked `git rev-parse` for every glob it saw. None of the three
# answers can change while this process runs, so paying for them per token bought
# nothing except the 22s that a 1900-token command spent against a 15s timeout.
#
# Held in arrays rather than newline strings so the readers iterate with no
# herestring either — `<<<` is a temp file per call, which is the same class of
# per-token syscall the fork was.
SPEC_STATE_PATHS=()
SPEC_STATE_BASES=()
SPEC_STATE_ABS=()
while IFS= read -r _s; do
  [ -z "$_s" ] && continue
  is_phase_state "$_s" || continue
  # The list is absolute now. A glob still has to be tried against the form the
  # command would have written — `rm -f .git/spec-gate/.spec-*` is relative —
  # so the project-relative spelling is carried alongside it when there is one.
  SPEC_STATE_ABS+=("$_s")
  SPEC_STATE_BASES+=("${_s##*/}")
  if [ -n "$GATE_DIR_REL" ]; then
    SPEC_STATE_PATHS+=("$GATE_DIR_REL/${_s##*/}")
  else
    SPEC_STATE_PATHS+=("$_s")
  fi
done <<< "$(spec_phase_state_list)"
SPEC_KEY_PATH_CACHE=$(spec_key_path 2>/dev/null) || SPEC_KEY_PATH_CACHE=""

# A glob is matched the other way round from an ordinary path: the token is the
# pattern and the state file is the subject, because that is what the shell will
# do with it.
glob_hits_state() {
  local tok=$1 i
  case "$tok" in
    *'*'*|*'?'*|*'['*) ;;
    *) return 1 ;;
  esac
  i=0
  while [ "$i" -lt "${#SPEC_STATE_PATHS[@]}" ]; do
    # shellcheck disable=SC2254
    case "${SPEC_STATE_PATHS[$i]}" in $tok) return 0 ;; esac
    # shellcheck disable=SC2254
    case "${SPEC_STATE_ABS[$i]}" in $tok) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

# find matches -name against the BASENAME, so the pattern has to be tried the
# same way. `-name '.spec-*'` names every state file and matches none of their
# full paths, which is how a filtered find that reaches all of them read as one
# that reaches none.
glob_hits_state_base() {
  local tok=$1 i
  case "$tok" in
    *'*'*|*'?'*|*'['*) ;;
    *) return 1 ;;
  esac
  i=0
  while [ "$i" -lt "${#SPEC_STATE_BASES[@]}" ]; do
    # shellcheck disable=SC2254
    case "${SPEC_STATE_BASES[$i]}" in $tok) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

STATE_MSG="The phase state is not yours to edit, move or remove — .spec-red, .spec-approval and .spec-validation included, because a receipt you could write by hand would assert RED without running anything, record an approval the user never gave, or claim this repo's checks passed with none of them run. Change phases with phase.sh <n>, verify RED with phase.sh red, record the Phase 4 checks with phase.sh validation, ask the user with phase.sh ask <gate>, and read the current phase with phase.sh status."

# Does this token name a state file, either as written or relative to a directory
# the same command cd'd into? `cd .claude && rm -f .spec-*` names nothing this
# hook recognises until the cd is applied, and a cd persists across && and ; —
# which is why the caller carries it across segments rather than resetting it.
state_token_hits() {
  local t=$1 cwd=$2
  is_phase_state "$t" && return 0
  glob_hits_state "$t" && return 0
  if [ -n "$cwd" ]; then
    case "$t" in
      /*) ;;
      *)  is_phase_state "$cwd/$t" && return 0
          glob_hits_state "$cwd/$t" && return 0 ;;
    esac
  fi
  return 1
}

# An interpreter's code argument is not shell and cannot be lexed as shell, so
# there is no token in it to recognise. Substring is the honest check here: it
# is a heuristic over something this hook genuinely cannot parse, and it errs
# toward refusing. It cannot see through obfuscation — see the threat model in
# the README, which says so rather than implying otherwise.
names_state_file() {
  case "$1" in
    *.spec-phase*|*.spec-baseline*|*.spec-red*|*.spec-approval*|\
    *.spec-scaffold*|*.spec-validation*|*spec-journal.md*|*review-log.jsonl*) return 0 ;;
  esac
  return 1
}

# The key that authenticates the validation marker, and the staging area
# `phase.sh red` puts the state in while it runs the configured test command.
# Neither is a working-tree path, which is the point — but neither was in any
# protected list either, so the marker's whole guarantee could be removed by
# replacing the key. A model that picks the key can mint any marker it likes,
# which is cheaper than forging one and was free. Checked at every phase: these
# are read by gates in phases 4 and 5, where the write-target scan has already
# exited.
# $2 = the directory the command cd'd into, if any. state_token_hits already
# takes it; without it here, `cd .git && rm -f spec-gate-*` named the key in a
# form no pattern matched.
names_gate_key() {
  local t=$1 cwd=${2:-}
  case "$t" in
    *spec-gate-key*) return 0 ;;
  esac
  if [ -n "$cwd" ]; then
    case "$t" in
      /*) ;;
      *) case "$cwd/$t" in
           *spec-gate-key*) return 0 ;;
         esac
         set -- "$cwd/$t" ;;
    esac
  fi
  # A glob reaches it without naming it: `rm -f .git/spec-gate-*` expands to the
  # key and matches no literal above. Deliberately narrow — `.claude/spec-gate-*`
  # must keep matching spec-gate-test-cmd, which is writable in every phase by
  # design, so the pattern is tried against the key path rather than the reverse.
  case "$1" in
    *'*'*|*'?'*|*'['*)
      # Resolved once at startup, not once per glob token: this forked
      # `git rev-parse` for every `*` in the command, and a command is allowed
      # to have two thousand of them.
      # shellcheck disable=SC2254
      [ -n "$SPEC_KEY_PATH_CACHE" ] && case "$SPEC_KEY_PATH_CACHE" in $1) return 0 ;; esac
      # shellcheck disable=SC2254
      case ".git/spec-gate-key" in $1) return 0 ;; esac ;;
  esac
  return 1
}

# The phase state left .claude/, but the journal and the review log did not, and
# they are the two things git has no copy of: what previous sessions did, and
# every verdict a reviewer returned. `rm -rf .claude` takes both, along with the
# hooks that would have noticed.
#
# Deliberately only the whole directory, and only under a destroying verb. The
# carve-out problem that made .claude the wrong home for phase state was about
# NARROW operations — `rm -f .claude/.spec-*`, `cd .claude && rm -f .spec-*` —
# which now reach nothing and are allowed again. Sweeping the directory is not
# something any legitimate step does.
RECORD_DIR_MSG="That removes $STATE_DIR_REL, which holds this task's journal and the reviewer verdict log — the record of what previous sessions did, which findings were acted on, and how far Execute got. Both are gitignored by design, so git has no copy and nothing brings them back. It also removes the hooks. If the intent is to end the task, that is 'phase.sh off'."

covers_record_dir() {
  local p=$1
  p=${p%/}; p=${p#./}
  [ -z "$p" ] && return 0
  case "$p" in
    .|..) return 0 ;;
    "$STATE_DIR_REL") return 0 ;;
    /*) case "${PROJECT_DIR%/}/$STATE_DIR_REL" in
          "$p"|"$p"/*) return 0 ;;
        esac ;;
  esac
  return 1
}

# `rm -rf .git` takes the key with everything else.
#
# The absolute arm mirrors covers_state_dir's, and its absence was the whole of
# the asymmetry: `rm -rf /abs/path/repo/.claude` was refused and
# `rm -rf /abs/path/repo/.git` was not, though the second is strictly worse — it
# takes the key, the review marker and the repository along with the state.
covers_git_dir() {
  local p=$1
  p=${p%/}; p=${p#./}
  [ -z "$p" ] && return 0
  case "$p" in
    .|..|.git) return 0 ;;
    /*) case "${PROJECT_DIR%/}/.git" in
          "$p"|"$p"/*) return 0 ;;
        esac ;;
  esac
  return 1
}

# --- Variables the command sets for itself -----------------------------------
# The verb filter skipped an assignment token whole, so nothing ever read its
# value — and a redirect target that is only `$V` names nothing and has no
# literal prefix to test, so the computed-target rule found nothing either. Past
# the phase-4 exit, where the write scan no longer runs, that left every state
# file writable through one variable.
#
# Only assignments this same command makes are resolved. The environment is not
# consulted: a variable this hook cannot see the value of stays unresolved, which
# is what keeps `> $LOGFILE` working.
VARS=""
VARS_ORDER=""
VARS_STALE=0

# Append-only, and deliberately so. This used to rewrite the whole binding list
# on every assignment to make the last write win — an O(n) string rebuild with a
# `<<<` temp file inside it, i.e. O(n^2) with a syscall per step. Measured: 400
# assignments 9.6s, 800 assignments 52s, 1000 assignments 120s, against a hook
# timeout of 15s. Every one of those was a silent ALLOW, because a killed hook
# emits no decision.
#
# Last-write-wins now happens once, in vars_order, where it costs one pass
# instead of one pass per assignment. (An associative array would be the obvious
# answer and is not available: /usr/bin/env bash is 3.2 on macOS, which is the
# platform this whole file's performance notes are written against.)
vars_record() {   # $1 = NAME=VALUE token
  local n=${1%%=*}
  case "$n" in
    ''|*[!A-Za-z0-9_]*) return 0 ;;
  esac
  VARS="$VARS$1"$'\n'
  VARS_STALE=1
  return 0
}

# The bindings in the order a resolver has to apply them: each name once, holding
# its LAST value, longest name first.
#
# Longest first is not a tidiness preference. Substitution is textual, so with `V`
# applied before `VX` the pattern `$V` consumes the prefix of `$VX` and the token
# resolves to <value-of-V> followed by a stray `X` — which is not what the shell
# would produce and, worse, is not what any later check would match. `V=s;
# VD=.claude; rm -rf $VD` was ALLOW for exactly that reason, while the same
# command without the decoy `V=s` was DENY. A binding that shadows nothing must
# not be able to hide one that does.
#
# Built lazily and cached, so an ordinary command with no assignments never runs
# it and a command with a thousand pays for one awk rather than one per token.
# The sort is inside awk for the same reason.
vars_order() {
  [ "$VARS_STALE" = 0 ] && return 0
  VARS_ORDER=$(printf '%s' "$VARS" | awk -F= '
    NF > 1 && $1 ~ /^[A-Za-z0-9_]+$/ { last[$1] = substr($0, length($1) + 2) }
    END {
      k = 0
      for (n in last) names[++k] = n
      for (i = 1; i < k; i++)
        for (j = i + 1; j <= k; j++)
          if (length(names[j]) > length(names[i])) {
            t = names[i]; names[i] = names[j]; names[j] = t
          }
      for (i = 1; i <= k; i++) printf "%s=%s\n", names[i], last[names[i]]
    }')
  VARS_STALE=0
  return 0
}

# Substitution anywhere in the token, not just a whole-token match. `.claude/$A`
# and `${V}-phase` name a state file just as surely as `$V` does, and a
# whole-token rule saw neither.
#
# The braced form is applied ahead of the bare one for every binding, because
# `${V}` is unambiguous where `$V` is a prefix of `$VX`. The ordering above is
# what settles the bare form.
resolve_tok() {   # sets RT to the token with this command's own bindings applied
  RT=$1
  case "$RT" in
    *'$'*) ;;
    *) return 0 ;;
  esac
  [ -z "$VARS" ] && return 0
  vars_order
  local line n v pat
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=${line%%=*}; v=${line#*=}
    pat="\${$n}"
    case "$RT" in *"$pat"*) RT=${RT//"$pat"/$v} ;; esac
  done <<< "$VARS_ORDER"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=${line%%=*}; v=${line#*=}
    pat="\$$n"
    case "$RT" in *"$pat"*) RT=${RT//"$pat"/$v} ;; esac
  done <<< "$VARS_ORDER"
  return 0
}

GATE_KEY_MSG="That path is the gate's own authentication material — the key the Phase 4 validation marker is signed with, or the state snapshot phase.sh red restores from. Neither is yours to write, move or remove: a marker signed with a key you chose proves nothing, and a snapshot you can edit is not a snapshot. Nothing in this workflow requires touching either."

scan_state_tokens() {
  local KIND VAL T TB IS_VERB VERB='' EXPECT_VERB=1 GITCLEAN=0 GITSTASH=0
  local FINDDIR=0 WANT_TARGET=0 HDOC='' STDIN_TAKEN=0 PIPED=0
  local FINDNAMED=0 FINDHIT=0 FINDPAT=0 WAS_TARGET=0 RT AV SHELL_SCRIPT=0
  local WANT_IN=0 WAS_REDIR=0 SHELL_DASH_S=0
  local depth=${2:-0} cwd=${3:-} CDNEXT=0
  [ "$depth" -gt 4 ] && deny "$OVERSIZE_MSG"
  [ "$depth" = 0 ] && budget_reset
  budget_input "$1"
  budget_lex
  local _toks; lex_cached "$1"; _toks=$LEXOUT
  while IFS=$'\t' read -r KIND VAL; do
    case "$KIND" in
      OVER) deny "$OVERSIZE_MSG" ;;
      # A cd survives a `;` or `&&`, so cwd deliberately does NOT reset here.
      SEP)
        # A heredoc is prose or a program depending on who is reading it, and
        # the verb is what says which. Decided at the end of the segment, where
        # both the verb and the whole body are known.
        if [ -n "$HDOC" ]; then
          case "$VERB" in
            sh|bash|zsh|ksh|dash|eval) scan_state_tokens "$HDOC" "$((depth + 1))" "$cwd" ;;
            python|python3|node|deno|bun|ruby|perl|php)
              names_state_file "$HDOC" && deny "$STATE_MSG" ;;
          esac
        fi
        # A shell whose script arrives on stdin runs something no token names.
        # `bash -s < script` and `cat script | bash` are both complete blind
        # spots — the redirect target is discarded and a pipe carries no text at
        # all — and both were allowed. Decided here because the redirect is
        # written after the verb. The heredoc form is handled just above, where
        # there is a body to read; these two have nothing to read, so they are
        # refused rather than guessed at.
        #
        # "Nothing to read" is the whole condition, and it was not being tested:
        # a redirect or a pipe was taken as proof that stdin is where the program
        # comes from, when it is only where stdin comes from. A shell given a -c
        # payload or a script operand already has its program, and the redirect
        # is feeding that program its INPUT — `echo hi | bash -c "echo hello"`
        # and `bash script.sh < input.txt` were both refused with the payload
        # sitting in plain sight, one token away. SHELL_SCRIPT records that the
        # segment supplied a program by some other route, and it is set at the
        # same place the payload is queued for scanning, so the two cannot drift.
        if [ -z "$HDOC" ] && [ "$SHELL_SCRIPT" = 0 ]; then
          case "$VERB" in
            sh|bash|zsh|ksh|dash)
              if [ "$STDIN_TAKEN" = 1 ] || [ "$PIPED" = 1 ]; then
                deny "This runs a shell whose script comes from stdin — a redirect or a pipe — so phase-guard has no text to evaluate and cannot tell what it would do. Run the script as an argument, or inline the commands, so the gate can see them."
              fi ;;
          esac
        fi
        VERB=''; EXPECT_VERB=1; GITCLEAN=0; GITSTASH=0; FINDDIR=0
        FINDNAMED=0; FINDHIT=0; FINDPAT=0; SHELL_SCRIPT=0; SHELL_DASH_S=0
        CDNEXT=0; WANT_TARGET=0; HDOC=''; STDIN_TAKEN=0
        # This SEP ends a segment and opens the next one; if it was a pipe, the
        # segment now beginning is the one whose stdin comes from it.
        case "$VAL" in pipe) PIPED=1 ;; *) PIPED=0 ;; esac
        continue ;;
      OP)   WANT_TARGET=1; continue ;;    # the redirect target arrives as the next WORD
      # `< file`: decides what a shell RUNS. WANT_IN marks the word after it,
      # because that word is the redirect's SOURCE and not an argument to the
      # verb — `bash -s < script.sh` has no script operand, and reading
      # `script.sh` as one would say it does.
      OPIN) STDIN_TAKEN=1; WANT_IN=1; continue ;;
      # Kept only when the verb makes it a program. Prose into `phase.sh
      # journal` is data and costs nothing — a plan document is legitimately
      # thousands of lines, and budgeting it would refuse the workflow's own
      # output. A script into a shell is bounded like any other scanned text.
      HBODY)
        case "$VERB" in
          sh|bash|zsh|ksh|dash|eval|python|python3|node|deno|bun|ruby|perl|php)
            budget_token "$VAL"; HDOC="$HDOC$VAL"$'\n' ;;
        esac
        continue ;;
    esac
    T=$VAL
    [ -z "$T" ] && continue
    budget_token "$T"

    # A write target the shell computes cannot be judged as a path. Phases 1-3
    # refuse every one of them further down, but that check sits below the
    # `PHASE -ge 4` exit — and Phase 4 is the only phase the validation marker
    # exists in, so the marker gating 4 -> 5 was writable through one `$(...)`.
    # Here it runs at every phase, narrowed to targets that name state, so
    # ordinary Phase 4 work like `> $LOGFILE` is untouched.
    WAS_TARGET=0
    WAS_REDIR=0
    if [ "$WANT_IN" = 1 ]; then
      WANT_IN=0
      WAS_REDIR=1
    fi
    if [ "$WANT_TARGET" = 1 ]; then
      WANT_TARGET=0
      WAS_TARGET=1
      WAS_REDIR=1
      # A variable this command set for itself is resolved first: `> $V` names
      # nothing on its own, and past the phase-4 exit nothing else looked.
      resolve_tok "$T"
      if [ "$RT" != "$T" ]; then
        state_token_hits "$RT" "$cwd" && deny "$STATE_MSG"
        names_gate_key "$RT" "$cwd" && deny "$GATE_KEY_MSG"
      fi
      case "$T" in
        *'$'*|*'`'*)
          # Two ways a computed target gives itself away. It spells a state name
          # somewhere in the text — `$(echo .claude/.spec-validation)` — or the
          # literal part before the first expansion already lands inside the
          # state directory, which is `.claude/$V`. Everything else is ordinary
          # work like `> $LOGFILE`, and is left alone at every phase.
          names_state_file "$T" && deny "This writes to a target the shell computes at runtime ($T), and the computed text names a phase state file. phase-guard cannot evaluate what it would resolve to, and the file it appears to name is one no command may write. $STATE_MSG"
          TPRE=${T%%[\$\`]*}
          case "$TPRE" in
            */*) covers_state_dir "${TPRE%/*}" \
                   && deny "This writes to a target the shell computes at runtime ($T), inside ${GATE_DIR_REL:-the gate directory} where the phase state lives. phase-guard cannot evaluate what it would resolve to, so it cannot rule out a state file. $STATE_MSG" ;;
          esac ;;
      esac
    fi

    IS_VERB=0
    if [ "$EXPECT_VERB" = 1 ] && [ "$WAS_TARGET" = 0 ]; then
      # The verb decides how every other token in the segment is read, so a verb
      # this hook cannot resolve is a command it cannot classify at all. A path
      # held in a variable was skipped by the assignment filter before anything
      # looked at its value: `P=.claude/hooks/phase.sh; $P 4 --force` advanced
      # the phase with the guard seeing a command whose verb it never knew.
      # Unresolvable is refused here, the way a computed write target already is.
      case "$T" in
        *'$'*|*'`'*)
          deny "The command in this segment is named by something the shell computes at runtime ($T), so phase-guard cannot tell what is about to run. It will not guess: a verb it cannot resolve could be any command, including the ones this gate exists to refuse. Write the command out literally." ;;
      esac
      # `*=*` is tested on the whole token, not the basename. `FOO=a/b` reduced
      # to `b`, which matches no assignment pattern, so the env prefix became
      # the verb and the real command was never classified at all.
      case "$T" in
        *=*)
          vars_record "$T"
          # The value is checked here, not only where the variable is used. A
          # resolver can always be walked around — indirect assignment, `read`,
          # a value built in pieces — but the literal has to appear somewhere,
          # and on the right of an `=` is the one place nothing was looking.
          AV=${T#*=}
          state_token_hits "$AV" "$cwd" && deny "$STATE_MSG"
          names_gate_key "$AV" "$cwd" && deny "$GATE_KEY_MSG"
          continue ;;
      esac
      tok_base "$T"
      tok_is_dispatch "$TB" && continue
      tok_skip_before_verb "$TB" && continue
      VERB=$TB
      EXPECT_VERB=0
      IS_VERB=1
      [ "$VERB" = cd ] && CDNEXT=1
    else
      if [ "$CDNEXT" = 1 ]; then
        CDNEXT=0
        case "$T" in
          -*) ;;
          /*) cwd=$T ;;
          *)  cwd=${cwd:+$cwd/}$T; cwd=${cwd#./} ;;
        esac
      fi
      case "$VERB" in
        git)
          [ "$T" = clean ] && GITCLEAN=1
          [ "$T" = stash ] && GITSTASH=1 ;;
        find)
          # A -name/-path pattern narrows what the find can reach. `find . -name
          # '*.pyc' -delete` roots at a directory that covers the state dir and
          # reaches none of it, and denying that made ordinary cleanup a phase
          # question. So a filtered find is judged on whether its filter can
          # match a state file, and an unfiltered one is judged on its root.
          if [ "$FINDPAT" = 1 ]; then
            FINDPAT=0
            FINDNAMED=1
            glob_hits_state_base "$T" && FINDHIT=1
            glob_hits_state "$T" && FINDHIT=1
            is_phase_state "$T" && FINDHIT=1
          else
            case "$T" in
              -name|-path|-iname|-ipath|-wholename) FINDPAT=1 ;;
              -*) ;;
              *) covers_state_dir "$T" && FINDDIR=1
                 covers_git_dir "$T" && FINDDIR=1
                 state_token_hits "$T" "$cwd" && FINDDIR=1 ;;
            esac
          fi ;;
      esac
      # `git clean -x` and `-X` no longer reach the phase state — that is under
      # the git directory, which git itself never cleans — but they do still
      # reach the journal and the review log, which are in the tree and
      # gitignored by design. Those are the durable record of what a previous
      # session did and of every verdict a reviewer returned, so no commit can
      # protect them and nothing else in this hook would ever see a path.
      if [ "$GITCLEAN" = 1 ]; then
        case "$T" in
          --) ;;
          -[!-]*) case "$T" in
                    *x*|*X*) deny "git clean -x/-X removes ignored files, and the journal and the review log are ignored by design — this would take the record of what previous sessions did and every verdict a reviewer returned, with nothing in git holding a copy. The phase state itself is safe under the git directory; this is about the history, which is the part that cannot be rebuilt. Clean specific paths instead, or run 'phase.sh off' if the intent is to end the task." ;;
                  esac ;;
        esac
      fi
      # `git stash --all` stashes ignored files too, which is the same act as
      # `clean -x` by another name: every state file goes, and `git stash` is
      # not a command anyone reads as destructive. `-u` is not included — it
      # takes untracked files and leaves ignored ones, so it never reaches these.
      if [ "$GITSTASH" = 1 ]; then
        case "$T" in
          --all) deny "git stash --all stashes ignored files as well as untracked ones, and the journal and the review log are ignored by design — this would take the record of what previous sessions did and every verdict a reviewer returned, exactly as 'git clean -x' would. Use 'git stash -u' if the intent is to set untracked work aside, or 'phase.sh off' if the intent is to end the task." ;;
          --) ;;
          -[!-]*) case "$T" in
                    *a*) deny "git stash -a stashes ignored files as well as untracked ones, and the journal and the review log are ignored by design — this would take the record of what previous sessions did and every verdict a reviewer returned, exactly as 'git clean -x' would. Use 'git stash -u' if the intent is to set untracked work aside, or 'phase.sh off' if the intent is to end the task." ;;
                  esac ;;
        esac
      fi
      # find reaches the same inodes with no path token that any check above
      # would recognise as a state file: `-delete` names nothing, and `-exec rm`
      # hides the verb behind an argument. POSIX find takes its paths before its
      # predicates, so the directory is always known by the time either appears.
      #
      # A -name/-path filter is honoured: it decides what the find can reach, so
      # a pattern that cannot match a state file makes the root irrelevant. An
      # unfiltered find is judged on its root alone, which is why `find . -type f
      # -delete` still refuses while `find . -name '*.pyc' -delete` does not.
      if [ "$FINDHIT" = 1 ] || { [ "$FINDDIR" = 1 ] && [ "$FINDNAMED" = 0 ]; }; then
        case "$T" in
          -delete|-exec|-execdir|-fprint|-fprintf)
            deny "This find would delete or overwrite inside ${GATE_DIR_REL:-the gate directory}, where the phase state lives. $STATE_MSG" ;;
        esac
      fi
      # An interpreter is handed code, not shell. It cannot be lexed here, so
      # the check is on whether the code names one of these files at all.
      case "$VERB" in
        python|python3|node|deno|bun|ruby|perl|php)
          case "$T" in
            -*) ;;
            *) names_state_file "$T" && deny "$STATE_MSG" ;;
          esac ;;
      esac
    fi

    # A quoted string handed to a shell is not data, it is shell. Re-read it,
    # the way collect_write_targets already does for write targets — otherwise
    # `bash -c "rm -f .claude/.spec-red"` is one opaque word to every check
    # below. Reading the raw command text used to cover this by accident.
    #
    # Arguments only. Recursing on the verb re-read the word `bash` as a command
    # whose verb is `bash`, forever, and the hook died on a stack overflow — a
    # crashed PreToolUse hook produces no JSON, which Claude Code reads as no
    # decision, so the fail-open was total.
    #
    # `-c'...'` with no space is one token beginning with a dash, which the flag
    # filter dropped whole — the payload rode in on the flag. The remainder after
    # the flag is the payload, so it is unwrapped rather than skipped.
    # A redirect's own word is never the program: it is the file the program
    # reads from or writes to. Recursing on it read `script.sh` in
    # `bash -s < script.sh` as an inline payload and, worse, as proof that the
    # segment had supplied a program at all — which is the one thing that turns
    # the stdin refusal above off.
    if [ "$IS_VERB" = 0 ] && [ "$WAS_REDIR" = 0 ]; then
      case "$VERB" in
        sh|bash|zsh|ksh|dash|eval)
          case "$T" in
            -c?*) SHELL_SCRIPT=1; scan_state_tokens "${T#-c}" "$((depth + 1))" "$cwd" ;;
            -c)   SHELL_SCRIPT=1 ;;   # payload is the next token, scanned below
            # `-s` says the script comes from stdin and every operand after it is
            # an ARGUMENT to that script, not the script. Without this,
            # `bash -s 4 --force < .claude/hooks/phase.sh` looked like a shell
            # that had been handed a program — the operand `4` — and the stdin
            # refusal switched itself off in front of the one command it exists
            # for. Bundled spellings count: `-es`, `-se`.
            -[!-]*) case "$T" in *s*) SHELL_DASH_S=1 ;; esac ;;
            -*)   ;;
            *)    [ "$SHELL_DASH_S" = 1 ] || SHELL_SCRIPT=1
                  scan_state_tokens "$T" "$((depth + 1))" "$cwd" ;;
          esac ;;
      esac
    fi

    state_token_hits "$T" "$cwd" && deny "$STATE_MSG"
    names_gate_key "$T" "$cwd" && deny "$GATE_KEY_MSG"
    # The same token with this command's own assignments applied. `rm -f $V`
    # names a state file only once V is read back.
    resolve_tok "$T"
    if [ "$RT" != "$T" ]; then
      state_token_hits "$RT" "$cwd" && deny "$STATE_MSG"
      names_gate_key "$RT" "$cwd" && deny "$GATE_KEY_MSG"
    fi

    # A token carrying a substitution cannot be matched as a path — `` `echo
    # .claude/.spec-phase` `` splits into words that each end or begin with a
    # backtick, so no exact pattern reaches them. If such a token spells a state
    # file at all, that is enough to refuse: nothing legitimate computes a path
    # that happens to read as this gate's own bookkeeping.
    case "$T" in
      *'$'*|*'`'*) names_state_file "$T" && deny "$STATE_MSG" ;;
    esac

    # `-exec`, `-execdir` and `-ok` introduce a command, so the token AFTER one
    # is a verb and everything past it belongs to that verb rather than to find.
    # finish_segment has had this arm since it was written; this walker never got
    # it, and the two disagreeing is what made
    # `find . -name '*.log' -exec rm -rf .claude {} \;` an ALLOW: `rm` was read
    # as one more find operand, so VERB stayed `find` and the destructive-verb
    # case below — the only thing that consults covers_state_dir — never ran.
    #
    # Set at the END of the body rather than the top, and without `continue`.
    # `-exec` is also the token the FINDHIT refusal above matches on, so a
    # version of this that short-circuited disarmed the filtered-find check it
    # was meant to complement: `find .claude -name '.spec-*' -exec rm {} ;`
    # stopped being refused for naming the state files, which it does, in order
    # to be refused for running rm, which it also does. Both have to fire.
    tok_opens_command "$T" && EXPECT_VERB=1

    # Removing the directory is removing the files in it. Restricted to verbs
    # that destroy, because `.claude` also holds the hooks, the settings and the
    # skills, and the model reads all three.
    case "$VERB" in
      rm|unlink|shred|rmdir|mv)
        case "$T" in
          -*) ;;
          *) covers_state_dir "$T" && deny "$STATE_MSG"
             covers_git_dir "$T" && deny "$GATE_KEY_MSG"
             covers_record_dir "$T" && deny "$RECORD_DIR_MSG"
             # `D=.claude; rm -rf $D` reaches the directory through a binding.
             resolve_tok "$T"
             covers_state_dir "$RT" && deny "$STATE_MSG"
             covers_git_dir "$RT" && deny "$GATE_KEY_MSG"
             covers_record_dir "$RT" && deny "$RECORD_DIR_MSG" ;;
        esac ;;
    esac
  done <<< "$_toks"
  return 0
}

if [ -n "$CMD" ]; then
  scan_state_tokens "$CMD"
fi
if [ -n "$PATHS" ] && is_phase_state "$PATHS"; then
  deny "The phase state is not yours to edit. Phases change by running phase.sh <n>, and the ones that are the user's change on an answer they gave — never by writing this file."
fi

# --- Who may advance a phase -------------------------------------------------
# Each phase widens what may be written, so the user is required exactly where
# write access expands, and nowhere else. Everything the model may do either
# restricts it or increases scrutiny.
#
# A PreToolUse hook cannot tell a Bash call the model chose to make from one a
# user's slash command told it to make — both arrive identically. That used to
# mean "the user decides" could not be expressed as an allow at all: it had to be
# an `ask`, or a denial pointing at a terminal.
#
# The approval receipt changes what this hook can know. It cannot see who made
# the call, but it can see whether the user answered the gate's question, because
# that answer came back through the host and was recorded by a PostToolUse hook
# the model has no way to write to. So the three approval gates now read a
# receipt first and allow on it, and fall back to the `ask` they always raised
# when there is no receipt to read. The fallback is not a leftover — it is what
# makes it safe to build on AskUserQuestion's undocumented result shape, since
# every way of failing to recognise an answer lands on the old behaviour.
#
# Everything that would route *around* those gates — forward skips, moves off
# Phase 5, `off` from 1-3, re-arming, --force — reads a receipt of its own. They
# were terminal-only for the same limitation, and they stop being terminal-only
# for the same reason: an answer through the host is evidence the user decided,
# which a permission prompt on a shell command never was.
# One line per phase.sh call in the command, each holding that call's own
# argument tail, prefixed with ':' so a call with no arguments is still a line.
#
# This used to be a regex over the raw command text — the mistake the token
# rewrite existed to end, still sitting one dispatch down. `.*phase\.sh` is
# greedy, so on a line with two calls it read the LAST; `head -1` read the first
# LINE. Either way the guard judged one call while the other ran, so appending
# `; phase.sh status` laundered any transition and any --force.
#
# Nested payloads are re-read for the same reason the state scan re-reads them:
# `bash -c "phase.sh 4 --force"` is one opaque word otherwise, and the old text
# regex caught it by accident.
# The walk calls eval_phase_call directly rather than printing its findings for
# a caller to read back. That is the whole point: `deny` is printf-then-exit, so
# collecting these through `$(phase_invocations ...)` put every refusal raised
# inside the walk — including the budget's — into the captured string, where the
# exit ended only the subshell and the hook went on to print nothing. No output
# reads as no decision, so the refusal became permission. Nothing that can refuse
# may run inside a command substitution.
phase_walk() {
  local KIND VAL T TB IN=0 ACC='' VERB='' EXPECT_VERB=1 HDOC='' XARGS=0 RT _toks
  local depth=${2:-0}
  [ "$depth" -gt 4 ] && deny "$OVERSIZE_MSG"
  [ "$depth" = 0 ] && budget_reset
  budget_input "$1"
  budget_lex
  lex_cached "$1"; _toks=$LEXOUT
  while IFS=$'\t' read -r KIND VAL; do
    case "$KIND" in
      OVER) deny "$OVERSIZE_MSG" ;;
      SEP)
        [ "$IN" = 1 ] && eval_phase_call "$ACC"
        # A phase.sh call inside a heredoc handed to a shell is a phase.sh call.
        if [ -n "$HDOC" ]; then
          case "$VERB" in
            sh|bash|zsh|ksh|dash|eval) phase_walk "$HDOC" "$((depth + 1))" ;;
          esac
        fi
        IN=0; ACC=''; VERB=''; EXPECT_VERB=1; HDOC=''; XARGS=0; continue ;;
      OP|OPIN) continue ;;
      HBODY)
        case "$VERB" in
          sh|bash|zsh|ksh|dash|eval) budget_token "$VAL"; HDOC="$HDOC$VAL"$'\n' ;;
        esac
        continue ;;
    esac
    T=$VAL
    [ -z "$T" ] && continue
    budget_token "$T"

    if [ "$EXPECT_VERB" = 1 ]; then
      case "$T" in *=*) vars_record "$T"; continue ;; esac
      tok_base "$T"
      # xargs builds the argument list from stdin, so a phase.sh reached through
      # it is a call whose arguments this hook cannot see at all. Noted before
      # the shared dispatcher test, which would otherwise skip past it silently.
      case "$TB" in xargs) XARGS=1; continue ;; esac
      tok_is_dispatch "$TB" && continue
      tok_skip_before_verb "$TB" && continue
      VERB=$TB; EXPECT_VERB=0
    else
      case "$VERB" in
        sh|bash|zsh|ksh|dash|eval)
          case "$T" in
            -c?*) phase_walk "${T#-c}" "$((depth + 1))" ;;
            -*)   ;;
            *)    phase_walk "$T" "$((depth + 1))" ;;
          esac ;;
      esac
    fi

    tok_base "$T"
    if [ "$TB" = phase.sh ]; then
      [ "$XARGS" = 1 ] && deny "This reaches phase.sh through xargs, which builds its argument list from stdin — so which phase it would move to, and whether --force is among the arguments, is not visible here. A transition this gate cannot read is one it will not allow. Run phase.sh with its arguments written out."
      [ "$IN" = 1 ] && eval_phase_call "$ACC"
      IN=1; ACC=''; continue
    fi
    # Arguments carry the destination phase and --force, so they are resolved
    # the same way a path is. The verb was refused when it could not be read;
    # the arguments were not, and `F=--force; phase.sh 5 $F` was the whole gate.
    if [ "$IN" = 1 ]; then
      resolve_tok "$T"
      ACC="$ACC $RT"
    fi
  done <<< "$_toks"
  [ "$IN" = 1 ] && eval_phase_call "$ACC"
  return 0
}

# Judges one phase.sh call. Every call in a command reaches this, and the first
# one that decides wins — decide/deny/ask exit, and every caller is in this shell.
eval_phase_call() {
  local ARGV=$1
  # An argument this hook cannot read is a transition it cannot judge, and
  # phase.sh has no gate of its own to fall back on. The verb was already
  # refused when unresolvable; the arguments carry the destination phase and
  # --force, so they get the same rule rather than being evaluated as if the
  # unreadable part were absent.
  case "$ARGV" in
    *'$'*|*'`'*)
      deny "This phase.sh call has an argument the shell computes at runtime ($ARGV), so which phase it would move to — and whether --force is among the arguments — cannot be read here. A transition this gate cannot evaluate is one it will not allow. Write the arguments out literally." ;;
  esac
  # ARG has to name the destination, and a flag never does. Taking the first
  # token blindly read `phase.sh --force 5` as ARG=--force, which is not 5, so
  # the force dispatch below fell through to the Phase 4 question — asking the
  # user about unlocking production code in order to decide a Phase 5 override.
  # That is the exact confusion the dispatch was split in two to end, reachable
  # by typing the same two words in the other order. Leading flags are skipped,
  # so the destination is found on whichever side of one it was written.
  #
  # Globbing is off for the walk: these are command-line tokens, and a `*` in
  # one would otherwise expand against the hook's own working directory.
  ARG=""
  set -f
  for _tok in $ARGV; do
    _tok=${_tok#[\"\']}; _tok=${_tok%[\"\']}
    case "$_tok" in
      ''|-*) continue ;;
      *) ARG=$_tok; break ;;
    esac
  done
  set +f

  # These five used to be "go run it in your own terminal", because a PreToolUse
  # hook cannot tell a Bash call the model chose from one a slash command made.
  # The receipt closes that: it does not say who called, but it proves the user
  # answered, because the answer came back through the host and was written by a
  # hook the model has no way to reach. So each one is now a question the model
  # may put, and the transition goes through on the answer.
  #
  # The fallback is the safety property and is deliberately today's behaviour: no
  # receipt, a stale one, or an answer nothing recognised all land on a denial.
  # What changed is what the denial tells you to do — ask, rather than leave the
  # session. Nothing here can proceed on the model's own say-so.
  gated_advance() {
    # $1 = gate name, $2 = what is being attempted, for the message
    case "$(approval_status "$1")" in
      approve)
        decide allow "The user was asked and approved this: $2. The answer was recorded from their reply, not from Claude." ;;
      decline)
        deny "The user was asked and declined this: $2. Do not look for another route, and do not ask again until something has actually changed — re-asking an answered question until the answer changes is not consent." ;;
      expired)
        deny "That answer was given at a different point in this task — another phase or slice — so it does not decide this one. Ask again: phase.sh ask $1" ;;
      *)
        deny "This needs the user, and they have not been asked yet: $2. Put the question to them — run 'phase.sh ask $1' and pass the JSON it prints to AskUserQuestion unchanged, then act on their answer. Current phase: $PHASE." ;;
    esac
  }

  # Deliberately not one helper for every caller. The three sites that used to
  # share advance_deny are three different decisions — skipping ahead, walking
  # away from an owed review, and abandoning before any code exists — and one
  # question standing for all three would be answered once and spent on whichever
  # came up. Each names its own gate.
  advance_deny() {
    gated_advance skip "advancing from phase $PHASE to phase $1, which skips the approval gates in between"
  }

  # --force is the user's override for a refused RED check, and it exists
  # precisely because the check is the thing standing between the model and
  # production writes. Denied in every phase, before ARG is even considered.
  # --force advances past the RED check on an assertion rather than on evidence,
  # which is why it is the one flag the model may never supply on its own. It is
  # still not the model's: what changed is that the user can now answer for it
  # here instead of leaving the session, and the answer is what allows it.
  #
  # Two flags share the spelling and skip different checks at different costs, so
  # they cannot share a question. `4 --force` unlocks production code with nothing
  # shown to fail; `5 --force` enters review with the repo's own checks unrun, at
  # a point where the code is already written. Routing both to the `force` gate
  # asked the user about unlocking production code in order to decide something
  # else entirely — and worse, one answer was then redeemable for the other,
  # since the receipt records the gate and not the transition. ARG is the first
  # non-flag token after phase.sh, so it names the destination phase whichever
  # side of the flag it was typed on.
  # Matched on ARGV, not on the whole command. Scanning the raw text meant the
  # flag was "present" when it appeared in a heredoc body — and `journal` and
  # `validation` exist to write prose about this workflow, which is prose that
  # says --force. Recording that you forced the RED gate was itself denied, and
  # the question the user got was about unlocking production code in order to
  # save a note. `git push --force && phase.sh status` did the same from a
  # command that has nothing to do with phases. ARGV is bounded to phase.sh's
  # own segment and stops at the first line, so both are outside it.
  #
  # Each flag is bound to the ONE transition whose check it skips, and that
  # binding is read off $PHASE rather than assumed. Without it this whole block
  # ran ahead of the phase matrix below and never consulted the current phase at
  # all, so a receipt bought for the adjacent step was spendable as a jump from
  # anywhere: with a force-validation answer on file, `phase.sh 5 --force` from
  # Phase 1 went to Phase 5 — past the spec approval, past RED, past 3 -> 4 —
  # and the guard allowed it, because "is --force approved" was the only question
  # being asked. The user answered "enter review with the checks unrun". They did
  # not answer "skip the entire workflow", and no wording of the force question
  # could have covered that, because the question is about a check and the act
  # was about four phases.
  #
  # A non-adjacent --force is refused outright rather than routed to the skip
  # gate. Two overrides stacked into one move is not a decision anyone can weigh
  # from a single prompt, and the honest route — retreat, then force the one step
  # — is one command longer and asks each question where it means something.
  case "$ARGV" in
    *--force*)
      case "$ARG" in
        5) [ "$PHASE" = 4 ] || deny "--force on a move to Phase 5 skips the validation report, and that report is what Phase 4 produces — so the flag only means anything on 4 -> 5. You are at phase $PHASE. Advance to Phase 4 first; the question about entering review unvalidated is asked there, where the work it describes exists. Current phase: $PHASE."
           gated_advance force-validation "advancing to Phase 5 with --force, which enters adversarial review with no record that this repo's own build, lint or test commands were ever run against the finished work" ;;
        4) [ "$PHASE" = 3 ] || deny "--force on a move to Phase 4 skips the RED check, and RED is what Phase 3 produces — so the flag only means anything on 3 -> 4. You are at phase $PHASE. Go to Phase 3 and write the failing tests; if they genuinely cannot be run here, the force question is asked there. Current phase: $PHASE."
           gated_advance force "advancing to Phase 4 with --force, which skips the RED check entirely and unlocks production code without anything having been shown to fail" ;;
        *) deny "--force is not a general override. It exists for exactly two transitions — 3 -> 4, which skips the RED check, and 4 -> 5, which skips the validation report — and each is a separate question the user answers about the check being given up. On a move to '$ARG' it names no check, so there is nothing for it to skip and nothing for anyone to have approved. Drop the flag. Current phase: $PHASE." ;;
      esac ;;
  esac

  case "$ARG" in
    status|"") ;;                       # read-only, always fine
    red) ;;                             # verification, not advancement — see below
    # Printing a question changes nothing, in any phase. Asking is not
    # approving: the answer arrives through the host, and only an answer moves a
    # gate. Allowing this freely is what makes the question the normal way to
    # reach a checkpoint rather than a step worth skipping.
    ask) ;;
    # Scaffold widens Phase 2 to create files that do not exist yet, so it is a
    # write-access expansion and takes the user's answer like the others. It also
    # requires the spec approval that precedes it: the surface being created is
    # the one they read in the spec, and creating it before they have accepted
    # the design is scaffolding a frontier nobody agreed to.
    scaffold)
      # Authorised by the spec approval rather than a gate of its own. Only one
      # .spec-approval exists at a time, so a second question asked in Phase 2
      # would overwrite the answer that 2 -> 3 still needs — and the spec is
      # where the surface being created is described anyway, which makes it the
      # honest place to ask.
      case "$(approval_status spec)" in
        approve-scaffold)
          decide allow "The user approved the spec and chose to have the new files created before the tests are written. Create only files that do not exist yet; nothing already tracked may be edited." ;;
        approve)
          deny "The user approved the spec, but chose the plain approval rather than 'Approve, and create the files first'. Scaffolding is not part of what they accepted. Go to Phase 3, or show them why the surface has to exist first and ask again: phase.sh ask spec" ;;
        decline)
          deny "The user sent the spec back, so there is no approved surface to scaffold. Revise the spec and ask again: phase.sh ask spec" ;;
        stale)
          deny "The spec has changed since the user answered, so their approval does not cover the surface now described in docs/specs/. Show them the spec as it stands and ask again: phase.sh ask spec" ;;
        expired)
          deny "That answer was given at a different point in this task — another phase or slice — so it does not decide this one. Ask again: phase.sh ask spec" ;;
        *)
          # No receipt to read. Under Claude Code that means the question was
          # never put; under Cursor it means it never can be — there is no
          # AskUserQuestion there, so approval_status is permanently `none` and a
          # receipt-only scaffold was unreachable. Since import-red now refuses
          # in Phase 3 and points here, that combination was a hard block on all
          # new-module work under Cursor. beforeShellExecution carries `ask`, so
          # this falls back the way every other gate already does.
          ask "Arm scaffold mode? Phase 2 is widened to CREATE files that do not exist yet, and only those — nothing already tracked can be edited, so no existing behaviour changes. This is what lets the tests written next fail on an assertion rather than on a missing import, which is the only failure that proves a test asserts anything. Note that the spec has not been approved through the gate's own question, so this is granting the widening on its own. Decline if you have not read docs/specs/ and accepted the surface it describes." ;;
      esac ;;
    slices)
      # Before the spec is approved the count is not approved either: the seams
      # are declared in the spec and the 2 -> 3 prompt covers them, so asking
      # separately would put the same question twice seconds apart.
      #
      # After that the total is something the user accepted, and changing it is
      # theirs. Nothing here asks *why* it changed, because the model has already
      # answered that by running this command at all: `slices` asserts more work
      # than estimated, and a design that turned out wrong routes to the 4 -> 2
      # contradiction path instead. The prompt's job is to surface the claim so
      # it can be rejected.
      if [ "$PHASE" -ge 3 ]; then
        ask "Change the number of slices this task lands in? It is currently slice $(slice_current) of $(slice_total), and that total is part of what you approved at 2 -> 3. Claude is asserting this is MORE WORK than estimated — not that the design is wrong. If you think the spec itself no longer holds, decline and ask it to retreat to Phase 2 for a re-approved spec. Whatever you accept, the slice checklist in docs/specs/ must be updated to match."
      fi ;;
    start)
      gated_advance restart "re-arming at Phase 1, which discards the task currently at phase $PHASE along with every approval already given" ;;
    off)
      # `off` from phases 1-3 grants production writes: same as jumping to 4.
      [ "$PHASE" -le 3 ] && gated_advance abandon "turning the gate off at phase $PHASE, before any production code has been written or any spec approved"
      # From 4 or 5 it expands nothing, which is why this used to be the model's
      # to take freely. That was wrong for a reason that has nothing to do with
      # write access: `off` ends the task, and the end of a task is the one
      # moment the user decides what happens to the work — ship it, keep
      # iterating, throw it away. A model that disarms on its own has skipped
      # that conversation and presented the outcome as settled.
      # Completion is checked here, on the way out, and never at Phase 5 —
      # `adversary` has to stay ignorant of the other slices, because telling it
      # "this is slice 2 of 5" invites it to excuse a gap as coming later, which
      # is the one thing a reviewer must refuse to grant.
      OFF_SLICES=""
      if slices_remain; then
        OFF_SLICES=" You are on slice $(slice_current) of $(slice_total), so $(( $(slice_total) - $(slice_current) )) more are unimplemented — ending now leaves the task half-built, and nothing afterwards remembers that it was sliced."
      fi
      # This is the gate the question buys the most on, because the decision was
      # never binary. A confirmation prompt can only offer yes or no, so the old
      # reason string had to ask in prose for a third answer — "if the work should
      # become a pull request, say so instead of accepting" — and hope. Three
      # options make each outcome something the guard can act on, and `continue`
      # becomes a refusal rather than a prompt the user declined for reasons
      # nothing recorded.
      case "$(approval_status close-out)" in
        pr)
          # Chosen "open a PR", so the PR comes first and disarming follows it.
          # Committing is how the review gate goes quiet, which makes a clean
          # tree the observable half of "the PR exists" — the same test the slice
          # boundary already uses, rather than a second idea of done.
          if [ -n "$(review_pending_paths)" ]; then
            deny "The user chose to open a pull request, and this work is not committed yet: $(review_pending_paths | tr '\n' ' '). Open the PR first, then disarm — that order is the whole point of the answer they gave. Disarming now would arm the review gate on every turn against this same diff."
          fi
          # OFF_SLICES rides on both allows, not just the fallback prompt. It
          # used to appear only when the model reached `off` WITHOUT asking —
          # i.e. on the path the workflow forbids — so an eight-slice task
          # answered through the gate disarmed after slice one with nothing on
          # screen about the other seven. The warning was there; it was wired to
          # the branch nobody takes.
          decide allow "The user chose to open a pull request and nothing is left uncommitted, so the work has shipped. Disarming is what they asked for next.${OFF_SLICES}" ;;
        disarm)
          decide allow "The user chose to disarm and keep the working tree as it stands. They were told the review gate returns to firing every turn while anything is uncommitted.${OFF_SLICES}" ;;
        continue)
          deny "The user chose to keep iterating in Phase 5, so the gate stays on and this task is not over. Say what is still outstanding and wait for them. Do not ask again until something has actually changed — re-asking an answered question until the answer changes is not consent." ;;
        slice)
          # They picked the boundary, not the end. Same shape as `continue`: an
          # answer that keeps the task alive can never be redeemed for `off`.
          deny "The user chose to commit this slice and open slice $(( $(slice_current) + 1 )) of $(slice_total), which is not a close-out — the task continues and the gate stays on. Commit the reviewed work, tick this slice off the checklist in docs/specs/, then run phase.sh 3 to open the next one." ;;
        expired)
          deny "That close-out answer was given at a different point in this task — a different phase or slice — so it does not decide this one. Ask again: phase.sh ask close-out" ;;
        *)
          ask "End the spec-driven workflow for this task?${OFF_SLICES} This is the close-out decision: the phase gate stops, and whatever is in the working tree is what you are left with. If the work should become a pull request, say so instead of accepting — that happens before disarming, not after. Note that turning the gate off makes the review gate fire on EVERY turn while the tree is dirty, so decline this if the diff is not committed yet." ;;
      esac ;;
    "$PHASE") ;;                        # no-op
    1|2|3|4|5)
      if [ "$PHASE" = 5 ]; then
        # Phases 1-4 suppress the Stop gate, so a move off 5 escapes the review
        # currently owed — it would launder an unreviewed diff into the next
        # slice's baseline, where nothing would look at it again.
        #
        # 5 -> 3 is the one exception, and only once that escape is closed: the
        # condition is that nothing is owed review, which is exactly what
        # review_pending_paths reports. That puts every slice boundary on a
        # commit, since committing is how the gate goes quiet. It stays the
        # model's move because it expands no write access — Phase 3 is stricter
        # than Phase 5, and the 3 -> 4 prompt is still ahead of it.
        if [ "$ARG" = 3 ] && [ "$(slice_current)" -lt "$(slice_total)" ]; then
          if [ -n "$(review_pending_paths)" ]; then
            deny "Slice $(slice_current) of $(slice_total) is not finished: its diff has not been reviewed and committed, and starting the next slice now would fold it into the new baseline where the review gate stops seeing it. Commit this slice, then advance. Outstanding: $(review_pending_paths | tr '\n' ' ')"
          fi
          :                               # next slice: this one is clean
        else
          gated_advance leave-review "moving from Phase 5 to phase $ARG while a diff is still owed review — phases 1 to 4 suppress the review gate, so nothing looks at it again"
        fi
      elif [ "$ARG" -lt "$PHASE" ]; then
        :                               # retreat: strictly more restrictive
      elif [ "$PHASE" = 1 ] && [ "$ARG" = 2 ]; then
        :                               # writing a spec is harmless; 2->3 is the gate
      elif [ "$PHASE" = 4 ] && [ "$ARG" = 5 ]; then
        :                               # self-submits to review
      elif [ "$PHASE" = 2 ] && [ "$ARG" = 3 ]; then
        # Spec approval, in band. The user is reading the spec in the
        # conversation anyway, so one confirmation is proportionate.
        #
        # The spec review this mentions is instructed, not enforced: no hook can
        # judge whether a subagent actually read the spec, and gating this
        # transition on a SubagentStop receipt would hand the workflow a hard
        # block whenever that payload shape changed. So the prompt does the one
        # thing it can — tell the user what should already be on screen, and
        # what its absence means.
        #
        # The prompt is now the fallback rather than the asking. If the model put
        # the question to the user properly, an approval receipt exists and this
        # transition is already decided — raising a second confirmation for a
        # decision made seconds ago is how a checkpoint becomes a reflex.
        #
        # Every unrecognised receipt state lands on that fallback, which is the
        # whole safety argument for building on an undocumented payload shape:
        # the worst case is the prompt this gate has always raised.
        case "$(approval_status spec)" in
          approve|approve-scaffold)
            decide allow "The user approved this spec through the gate's own question, and no spec document has changed since they answered." ;;
          decline)
            deny "The user was asked and sent the spec back, and nothing in docs/specs/ has changed since. Revise the spec against what they said, then ask again: phase.sh ask spec" ;;
          stale)
            deny "The user's approval does not match what is in docs/specs/ now: either a document moved since they answered, or there was nothing there to approve when they did. Either way it does not cover the spec on disk. Show them the spec as it stands and ask again: phase.sh ask spec" ;;
          expired)
            deny "That approval was given at a different point in this task, so it is an answer about something else. Ask again: phase.sh ask spec" ;;
          *)
            ask "Approve the spec and advance to Phase 3 (Plan + failing tests)? Approving asserts that you have read docs/specs/ and accept the approach, the types, and the out-of-scope list. The spec should have been through the spec-adversary reviewer first: if you have not seen its verdict in this conversation, decline and ask for it. Phase 3 writes tests only; production code stays blocked until Phase 4." ;;
        esac
      elif [ "$PHASE" = 3 ] && [ "$ARG" = 4 ]; then
        # Unlocking production code. This used to be terminal-only, on the
        # grounds that a permission prompt is a low-attention action and the RED
        # claim was pure assertion — a reflex click would have hollowed it out.
        #
        # The receipt is what changes that. `phase.sh red` has run the tests as a
        # tool call, so the failure output is in the transcript the user is
        # already reading, and the receipt pins the content of every test file it
        # saw fail. Approving is now a judgment on visible evidence rather than a
        # click standing in for a check nobody did.
        #
        # Without a valid receipt this stays a denial. The prompt is only worth
        # offering when there is something on screen to approve.
        # Two receipts, and both are required. The RED receipt says the machine
        # checked something; the approval receipt says the user judged it. Neither
        # substitutes for the other, and the order is fixed — there is nothing to
        # ask about until the failures are on screen.
        case "$(red_receipt_status)" in
          valid)
            case "$(approval_status red)" in
              approve)
                decide allow "The user read the failures and accepted them through the gate's own question, and the RED receipt they were shown is unchanged." ;;
              decline)
                deny "The user was asked and said one of those tests failed for the wrong reason. Fix it, re-run phase.sh red, and ask again: phase.sh ask red" ;;
              stale)
                deny "The RED receipt has been rewritten since the user answered, so they accepted a different set of failures from the one on disk. Show the new output and ask again: phase.sh ask red" ;;
              expired)
                deny "That answer was given at a different point in this task, so it is an answer about other failures. Re-run phase.sh red and ask again: phase.sh ask red" ;;
              *)
                ask "Advance to Phase 4 (Execute) and unlock production code? RED is mechanically verified: the tests this phase added were run and failed, and none of them has changed since. What that does NOT prove is that they failed for the reason the spec expects — that is the part you are approving. Read the failure output above before accepting." ;;
            esac ;;
          stale)
            deny "The RED verification is stale: the test files have changed since they were checked. Run phase.sh red again, show the output, and then ask to advance. Current phase: $PHASE." ;;
          *)
            deny "RED has not been verified yet, so Phase 4 stays locked. Run phase.sh red — it runs the tests this phase changed and refuses if they pass. Show the failure output, say why each failure is the expected one, then advance. If this repo has no test command configured, write one to .claude/spec-gate-test-cmd — that path is gate config, not production code, and is writable in every phase — then run the check. Work out the command from package.json, pyproject.toml, the Makefile or CI rather than guessing. Only ask the force gate if nothing in the repo says how its tests run: forcing spends the user's approval in place of evidence you could have produced." ;;
        esac
      else
        advance_deny "$ARG"
      fi ;;
  esac
  return 0
}

# The write scan comes first, and it can only ever DENY — it has no allow to
# give. `decide` exits, so whichever check speaks first speaks for the whole
# command: with the phase walk in front, `phase.sh status ; echo pwned >
# src/x.ts` was allowed on the strength of the status call, and an explicit hook
# allow bypasses the permission system rather than merely skipping a phase.
# Ordering the refusals ahead of the decisions is what makes an allow mean "and
# nothing else in this command objects".
# PATHS_ARE_SHELL says where the paths below came from, and the two sources are
# not the same kind of evidence. A target dug out of a command string is a guess
# about what the shell will do; a `file_path` on an Edit or a Write is the exact
# path the tool was handed. Only the first can be "computed at runtime".
PATHS_ARE_SHELL=0
if [ "$PHASE" -lt 4 ] && [ -n "$CMD" ]; then
  collect_write_targets "$CMD"
  PATHS=$CAND
  PATHS_ARE_SHELL=1
fi

run_write_scan() {

while IFS= read -r P; do
  [ -z "$P" ] && continue

  # A target the shell would compute at runtime cannot be judged here. Only
  # write targets reach this point, so denying is narrow: a read-only command
  # like `grep foo $(git ls-files)` produces no target and never gets here.
  #
  # Structured fields are exempt, and that exemption is the fix rather than a
  # loophole: `$` is an ordinary character in a filename, and a Write to
  # `src/cost$total.ts` was being refused at Phase 4 as an unevaluable shell
  # expression when no shell was involved and the phase permits the write
  # anyway. The removal of the old `PHASE -ge 4` early exit is what exposed it —
  # PATHS is set for Edit/Write in every phase, so phases 4 and 5 started
  # running structured paths through a scanner written for guessed-at ones.
  # Everything else below still applies at every phase, deliberately: the
  # one-tree-per-task check is not phase policy, and a write into a sibling
  # worktree is exactly as unjudgeable at Phase 4 as at Phase 1.
  if [ "$PATHS_ARE_SHELL" = 1 ]; then
    case "$P" in
      *'$'*|*'`'*)
        # A binding this same command made is not something the hook "cannot
        # evaluate" — it is written down one token away, and the state scan has
        # resolved exactly these since it learned to. Refusing them here made the
        # two scans disagree about the same text: `V=.claude/x; rm -f $V` was
        # judged on what V holds, while `V=tests/a.ts; echo x > $V` was refused
        # for being unjudgeable. VARS is populated by the state walk, which runs
        # before this.
        resolve_tok "$P"
        case "$RT" in
          *'$'*|*'`'*)
            deny "Phase $PHASE of spec-driven: this command writes to a target the shell computes at runtime ($P), which phase-guard cannot evaluate. Use Write or Edit for file changes during phases 1-3." ;;
          '')
            deny "Phase $PHASE of spec-driven: this command writes to a target the shell computes at runtime ($P), which phase-guard cannot evaluate. Use Write or Edit for file changes during phases 1-3." ;;
          *) P=$RT ;;
        esac ;;
    esac
  fi

  # /dev/null, /tmp scratch, ~/.config: not repo work, and never were.
  #
  # But "outside PROJECT_DIR" also describes a path in another worktree of this
  # same repo, and that is repo work — in a tree this gate cannot judge. Skipping
  # it was the second half of the split fail-open: armed in the main checkout,
  # writing production code into the worktree, allowed because the path did not
  # start with PROJECT_DIR.
  if ! in_project "$P"; then
    case "$P" in
      /*) ;;
      *)  continue ;;                   # relative: already scored as in-project
    esac
    PN=$(spec_norm_path "$P")
    PROOT=$(spec_realpath "${PROJECT_DIR%/}")
    case "$PN" in
      "$PROOT"/*) : ;;                  # the same tree once symlinks are resolved
      *)
        while IFS= read -r WTREE; do
          [ -n "$WTREE" ] || continue
          WTREE=$(spec_realpath "$WTREE")
          { [ -n "$WTREE" ] && [ "$WTREE" != "$PROOT" ]; } || continue
          case "$PN" in
            "$WTREE"/*) deny "$(spec_split_message "$PROOT" "$WTREE")" ;;
          esac
        done <<< "$(spec_worktrees "$PROJECT_DIR")"
        continue ;;
    esac
  fi
  is_phase_state "$P" && deny "The phase state is not yours to write."
  path_allowed_in_phase "$PHASE" "$P" || deny "$DENY_REASON"
done <<< "$PATHS"
  return 0
}

[ -n "$PATHS" ] && run_write_scan

[ -n "$CMD" ] && phase_walk "$CMD"

exit 0
