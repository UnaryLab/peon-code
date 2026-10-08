#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)

command -v python3 >/dev/null 2>&1 || { echo 'trust: SKIP (python3 unavailable)'; exit 0; }
export TRUST_TEST_PYTHON
TRUST_TEST_PYTHON=$(command -v python3)
fake_bin=$(make_fake_commands)
cat >"$fake_bin/python3" <<'PYTHON_WRAPPER'
#!/usr/bin/env bash
case ${2:-} in
  */.claude.json) printf 'trust-python\n' >>"$FAKE_TMUX_LOG" ;;
esac
exec "$TRUST_TEST_PYTHON" "$@"
PYTHON_WRAPPER
printf '#!/usr/bin/env bash\nexit 1\n' >"$fake_bin/git"
chmod +x "$fake_bin/python3" "$fake_bin/git"

work_dir="$TEST_DIR/trust work '\"\\dir"$'\t\r\n'end
home_dir="$TEST_DIR/trust-home"
trust_config_dir="$TEST_DIR/trust-config"
codex_config_dir="$home_dir/.codex"
log="$TEST_DIR/trust.log"
mkdir -p "$work_dir" "$home_dir" "$trust_config_dir" "$codex_config_dir"
work_dir=$(cd "$work_dir" && pwd)
printf 'compact-at 0\nfirst claude -\nsecond claude -\nimpl codex -\n' >"$work_dir/peon-code.conf"
printf 'model = "keep-model"\n[features]\n# end\nkeep_feature = true' >"$codex_config_dir/config.toml"
chmod 640 "$codex_config_dir/config.toml"
cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-original.toml"

project_header() {
  local key=$1
  key=${key//\\/\\\\}
  key=${key//\"/\\\"}
  key=${key//$'\n'/\\n}
  key=${key//$'\r'/\\r}
  key=${key//$'\t'/\\t}
  printf '[projects."%s"]\n' "$key"
}

run_launch() (
  cd "$work_dir"
  PATH="$fake_bin:$PATH" HOME="$home_dir" CLAUDE_CONFIG_DIR="$trust_config_dir" CODEX_HOME="$codex_config_dir" TMPDIR="$TEST_DIR" \
    FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_CMD=node FAKE_TMUX_PANES=${trust_test_panes:-3} \
    FAKE_TMUX_CAPTURE=$'output\n❯\n────' "$ROOT/peon-code.sh" trust-test
) </dev/null >"$TEST_DIR/trust.out" 2>"$TEST_DIR/trust.err"

python3 - "$trust_config_dir/.claude.json" "$work_dir" <<'PYTHON'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as file:
    json.dump({"keep": [1, "unchanged"], "projects": {
        "/other": {"hasTrustDialogAccepted": False, "history": ["old"]},
        sys.argv[2]: {"history": ["current"], "hasTrustDialogAccepted": False}}}, file)
PYTHON
run_launch
cp "$TEST_DIR/codex-original.toml" "$TEST_DIR/codex-expected.toml"
printf '\n\n%s\n%s\n' "$(project_header "$work_dir")" 'trust_level = "trusted"' >>"$TEST_DIR/codex-expected.toml"
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-expected.toml" || fail 'Codex append changed existing keys'
case $(ls -l "$codex_config_dir/config.toml") in
  -rw-r-----*) ;;
  *) fail 'Codex config mode changed' ;;
esac
assert_not_contains "$log" 'trust_level'
python3 - "$trust_config_dir/.claude.json" "$work_dir" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    data = json.load(file)
assert data == {"keep": [1, "unchanged"], "projects": {
    "/other": {"hasTrustDialogAccepted": False, "history": ["old"]},
    sys.argv[2]: {"history": ["current"], "hasTrustDialogAccepted": True}}}
PYTHON
[ "$(grep -c '^trust-python$' "$log")" = 1 ] || fail 'Claude trust ran more than once'
trust_line=$(grep -n '^trust-python$' "$log" | cut -d: -f1)
launch_line=$(grep -n '^buffer-content:' "$log" | head -1 | cut -d: -f1)
[ "$trust_line" -lt "$launch_line" ] || fail 'agents started before Claude trust setup'
cp "$trust_config_dir/.claude.json" "$TEST_DIR/trusted-original.json"
cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-trusted-original.toml"
: >"$log"
run_launch
cmp "$trust_config_dir/.claude.json" "$TEST_DIR/trusted-original.json" || fail 'Claude trust is not idempotent'
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-trusted-original.toml" || fail 'Codex existing header was rewritten'

trust_config_dir=''
printf '{"keep": true}\n' >"$home_dir/.claude.json"
: >"$log"
run_launch
python3 - "$home_dir/.claude.json" "$work_dir" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    assert json.load(file) == {"keep": True, "projects": {
        sys.argv[2]: {"hasTrustDialogAccepted": True}}}
PYTHON

codex_config_dir="$TEST_DIR/codex-missing/nested"
: >"$log"
run_launch
printf '%s\n%s\n' "$(project_header "$work_dir")" 'trust_level = "trusted"' >"$TEST_DIR/codex-missing-expected.toml"
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-missing-expected.toml" || fail 'missing Codex config not created'

printf 'keep = "unchanged"\n%s\ntrust_level = "untrusted"\n' "$(project_header "$work_dir")" >"$codex_config_dir/config.toml"
cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-untrusted-original.toml"
: >"$log"
run_launch
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-untrusted-original.toml" || fail 'existing untrusted Codex entry changed'

trust_config_dir="$TEST_DIR/trust-missing"
mkdir -p "$trust_config_dir"
: >"$log"
run_launch
[ ! -e "$trust_config_dir/.claude.json" ] || fail 'missing Claude config was created'
[ "$(grep -c 'skipping Claude project trust' "$TEST_DIR/trust.err")" = 1 ] || fail 'missing config note repeated'
assert_not_contains "$log" trust-python
assert_contains "$log" 'buffer-content:claude'

printf '{malformed JSON\n' >"$trust_config_dir/.claude.json"
cp "$trust_config_dir/.claude.json" "$TEST_DIR/malformed-original.json"
: >"$log"
run_launch
cmp "$trust_config_dir/.claude.json" "$TEST_DIR/malformed-original.json" || fail 'malformed config changed'
[ "$(grep -c 'could not set Claude project trust' "$TEST_DIR/trust.err")" = 1 ] || fail 'parse failure note repeated'
assert_contains "$log" 'buffer-content:claude'

cat >"$TEST_DIR/no-python.sh" <<'NO_PYTHON'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = python3 ]; then return 1; fi
  builtin command "$@"
}
NO_PYTHON
: >"$log"
codex_config_dir="$TEST_DIR/codex-no-python"
BASH_ENV="$TEST_DIR/no-python.sh" run_launch
cmp "$trust_config_dir/.claude.json" "$TEST_DIR/malformed-original.json" || fail 'config changed without Python'
[ "$(grep -c 'skipping Claude project trust' "$TEST_DIR/trust.err")" = 1 ] || fail 'missing Python note repeated'
assert_not_contains "$log" trust-python
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-missing-expected.toml" || fail 'Codex trust needed Python'

physical_dir=$work_dir
ln -s "$physical_dir" "$TEST_DIR/project-link"
work_dir="$TEST_DIR/project-link"
trust_config_dir="$TEST_DIR/trust-linked-config"
codex_config_dir="$TEST_DIR/codex-linked-config"
mkdir -p "$trust_config_dir" "$TEST_DIR/trust-target"
config_target="$TEST_DIR/trust-target/config.json"
printf '{"keep": true}\n' >"$config_target"
chmod 640 "$config_target"
ln -s "$config_target" "$trust_config_dir/.claude.json"
: >"$log"
run_launch
python3 - "$trust_config_dir/.claude.json" "$config_target" "$physical_dir" "$work_dir" <<'PYTHON'
import json
import os
import stat
import sys

link, target, physical, logical = sys.argv[1:]
assert os.path.islink(link) and os.path.realpath(link) == target
assert stat.S_IMODE(os.stat(target).st_mode) == 0o640
with open(target, encoding="utf-8") as file:
    assert json.load(file) == {"keep": True, "projects": {
        physical: {"hasTrustDialogAccepted": True},
        logical: {"hasTrustDialogAccepted": True}}}
PYTHON
printf '%s\n%s\n\n\n%s\n%s\n' "$(project_header "$physical_dir")" 'trust_level = "trusted"' \
  "$(project_header "$work_dir")" 'trust_level = "trusted"' >"$TEST_DIR/codex-linked-expected.toml"
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-linked-expected.toml" || fail 'Codex did not trust both project paths'
assert_not_contains "$log" 'trust_level'

codex_config_dir="$TEST_DIR/codex-mixed"
mkdir -p "$codex_config_dir"
printf '%s\ntrust_level = "untrusted"\n' "$(project_header "$physical_dir")" >"$codex_config_dir/config.toml"
cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-mixed-expected.toml"
printf '\n\n%s\ntrust_level = "trusted"\n' "$(project_header "$work_dir")" >>"$TEST_DIR/codex-mixed-expected.toml"
: >"$log"
run_launch
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-mixed-expected.toml" || fail 'Codex changed an existing path while adding the other path'

printf 'compact-at 0\nimpl codex -\n' >"$work_dir/peon-code.conf"
trust_test_panes=1
: >"$log"
run_launch
assert_contains "$log" 'buffer-content:codex --no-alt-screen'
assert_not_contains "$log" trust-python
assert_not_contains "$TEST_DIR/trust.err" 'Claude project trust'
assert_not_contains "$log" 'trust_level'

codex_config_dir=''
home_dir="$TEST_DIR/codex-default-home"
: >"$log"
run_launch
cmp "$home_dir/.codex/config.toml" "$TEST_DIR/codex-linked-expected.toml" || fail 'Codex default config directory not used'

codex_config_dir="$TEST_DIR/codex-config-link"
codex_target_dir="$TEST_DIR/codex-config-target"
mkdir -p "$codex_config_dir" "$codex_target_dir"
printf '# keep target\n' >"$codex_target_dir/actual.toml"
chmod 640 "$codex_target_dir/actual.toml"
ln -s actual.toml "$codex_target_dir/middle.toml"
ln -s ../codex-config-target/middle.toml "$codex_config_dir/config.toml"
printf '# keep target\n\n\n%s\n%s\n\n\n%s\n%s\n' "$(project_header "$physical_dir")" 'trust_level = "trusted"' \
  "$(project_header "$work_dir")" 'trust_level = "trusted"' >"$TEST_DIR/codex-link-expected.toml"
: >"$log"
run_launch
[ -L "$codex_config_dir/config.toml" ] || fail 'Codex config symlink replaced'
[ -L "$codex_target_dir/middle.toml" ] || fail 'Codex chained config symlink replaced'
[ "$(readlink "$codex_config_dir/config.toml")" = ../codex-config-target/middle.toml ] || fail 'Codex relative symlink changed'
cmp "$codex_target_dir/actual.toml" "$TEST_DIR/codex-link-expected.toml" || fail 'Codex linked target not updated'
case $(ls -l "$codex_target_dir/actual.toml") in
  -rw-r-----*) ;;
  *) fail 'Codex linked target mode changed' ;;
esac

codex_config_dir="$TEST_DIR/codex-config-cycle"
mkdir -p "$codex_config_dir"
ln -s other.toml "$codex_config_dir/config.toml"
ln -s config.toml "$codex_config_dir/other.toml"
: >"$log"
run_launch
assert_contains "$TEST_DIR/trust.err" 'could not resolve Codex config link'
[ -L "$codex_config_dir/config.toml" ] || fail 'Codex config cycle changed'
[ -L "$codex_config_dir/other.toml" ] || fail 'Codex config cycle target changed'

work_dir="$TEST_DIR/simple-project"
mkdir -p "$work_dir"
printf 'compact-at 0\nimpl codex -\n' >"$work_dir/peon-code.conf"
for format in commented literal dotted note; do
  codex_config_dir="$TEST_DIR/codex-presence-$format"
  mkdir -p "$codex_config_dir"
  case $format in
    commented) printf '[projects."%s"] # existing\ntrust_level = "trusted"\n' "$work_dir" ;;
    literal) printf "[projects.'%s']\ntrust_level = \"trusted\"\n" "$work_dir" ;;
    dotted) printf '[projects]\n"%s".trust_level = "trusted"\n' "$work_dir" ;;
    note) printf '# remembered project "%s"\n' "$work_dir" ;;
  esac >"$codex_config_dir/config.toml"
  cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-presence-original.toml"
  : >"$log"
  run_launch
  cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-presence-original.toml" || fail "Codex rewrote a path in $format form"
  assert_not_contains "$TEST_DIR/trust.err" 'inline projects table'
done

for format in sibling child bare; do
  codex_config_dir="$TEST_DIR/codex-quoted-$format"
  mkdir -p "$codex_config_dir"
  case $format in
    sibling) printf '[projects."%s-old"]\ntrust_level = "untrusted"\n' "$work_dir" ;;
    child) printf "[projects.'%s/sub']\ntrust_level = \"untrusted\"\n" "$work_dir" ;;
    bare) printf '# remembered project %s\n' "$work_dir" ;;
  esac >"$codex_config_dir/config.toml"
  cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-quoted-expected.toml"
  printf '\n\n%s\ntrust_level = "trusted"\n' "$(project_header "$work_dir")" >>"$TEST_DIR/codex-quoted-expected.toml"
  : >"$log"
  run_launch
  cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-quoted-expected.toml" || fail "Codex skipped current project due to $format text"
done

codex_config_dir="$TEST_DIR/codex-inline-projects"
inline_note='peon-code: config.toml has an inline projects table; skipping codex project trust'
mkdir -p "$codex_config_dir"
printf '  projects\t= {"%s/other-project" = {trust_level = "untrusted"}}\n' "$TEST_DIR" >"$codex_config_dir/config.toml"
cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-inline-original.toml"
: >"$log"
run_launch
cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-inline-original.toml" || fail 'Codex extended an inline projects table'
[ "$(grep -Fxc -- "$inline_note" "$TEST_DIR/trust.err")" = 1 ] || fail 'Codex inline projects note not emitted once'
ln -s "$work_dir" "$TEST_DIR/inline-project-link"
work_dir="$TEST_DIR/inline-project-link"
for format in double single; do
  codex_config_dir="$TEST_DIR/codex-inline-$format"
  mkdir -p "$codex_config_dir"
  case $format in
    double) printf '  "projects" = {"%s/other-project" = {trust_level = "untrusted"}}\n' "$TEST_DIR" ;;
    single) printf "  'projects' = {\"%s/other-project\" = {trust_level = \"untrusted\"}}\n" "$TEST_DIR" ;;
  esac >"$codex_config_dir/config.toml"
  cp "$codex_config_dir/config.toml" "$TEST_DIR/codex-inline-original.toml"
  : >"$log"
  run_launch
  cmp "$codex_config_dir/config.toml" "$TEST_DIR/codex-inline-original.toml" || fail "Codex extended a $format quoted inline projects table"
  [ "$(grep -Fxc -- "$inline_note" "$TEST_DIR/trust.err")" = 1 ] || fail "Codex $format inline projects note not emitted once for both paths"
done
echo 'trust: PASS'
