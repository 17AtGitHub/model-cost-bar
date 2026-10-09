#!/usr/bin/env bash
# <xbar.title>Model Cost</xbar.title>
# <xbar.version>v0.1.0</xbar.version>
# <xbar.author>Daksh Kochhar</xbar.author>
# <xbar.author.github>17AtGitHub</xbar.author.github>
# <xbar.desc>Shows what each AI model costs per prompt, so you can pick before you spend.</xbar.desc>
# <xbar.dependencies>bash,curl,awk</xbar.dependencies>
# <xbar.abouturl>https://github.com/17AtGitHub/model-cost-bar</xbar.abouturl>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

set -u

PRICES_URL="${MODEL_COST_PRICES_URL:-https://raw.githubusercontent.com/17AtGitHub/model-cost-bar/main/prices.tsv}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/model-cost"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/model-cost"
MODELS_FILE="$CONFIG_DIR/models"
MINE_FILE="$CONFIG_DIR/mine"
MODE_FILE="$CONFIG_DIR/mode"
PRICES_FILE="$CACHE_DIR/prices.tsv"
TURN_IN=100000
TURN_OUT=10000
MAX_SHOWN=4
SYNC_EVERY_MIN=1440
GRAY="#8E8E93"

mkdir -p "$CONFIG_DIR" "$CACHE_DIR"

if [ ! -f "$MODELS_FILE" ]; then
  cat >"$MODELS_FILE" <<'EOF'
# Models shown in the menu bar. The first 4 valid lines are shown, most expensive first.
# Use an id from the "Add a model" menu, or add a custom model as:  Name | input $ per 1M | output $ per 1M
claude-fable-5-1
claude-opus-5-5
gpt-5.6-terra
xai/grok-4.7
EOF
fi

sync_prices() {
  local tmp="$PRICES_FILE.tmp"
  if curl -fsL --max-time 10 "$PRICES_URL" -o "$tmp" 2>/dev/null && head -1 "$tmp" | grep -q "^id"$'\t'; then
    mv "$tmp" "$PRICES_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

remove_model() {
  awk -v id="$1" '
    {
      line = $0; sub(/#.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
      key = line
      if (index(line, "|") > 0) { split(line, p, "|"); nm = p[1]; gsub(/^[ \t]+|[ \t]+$/, "", nm); key = "custom:" nm }
      if (line != "" && key == id) next
      print
    }' "$MODELS_FILE" >"$MODELS_FILE.tmp" && mv "$MODELS_FILE.tmp" "$MODELS_FILE"
}

case "${1:-}" in
  mine) printf '%s\n' "${2:-}" >"$MINE_FILE"; exit 0 ;;
  mode) printf '%s\n' "${2:-}" >"$MODE_FILE"; exit 0 ;;
  sync) sync_prices; exit 0 ;;
  remove) remove_model "${2:-}"; exit 0 ;;
  add)
    if [ -s "$MODELS_FILE" ] && [ -n "$(tail -c1 "$MODELS_FILE")" ]; then echo >>"$MODELS_FILE"; fi
    printf '%s\n' "${2:-}" >>"$MODELS_FILE"
    exit 0
    ;;
esac

sync_failed=0
if [ ! -s "$PRICES_FILE" ] || [ -z "$(find "$PRICES_FILE" -mmin -"$SYNC_EVERY_MIN" 2>/dev/null)" ]; then
  sync_prices || sync_failed=1
fi

if [ ! -s "$PRICES_FILE" ]; then
  echo "Model cost ?"
  echo "---"
  echo "Couldn't download prices | color=$GRAY"
  echo "Try again | bash=\"$0\" param1=sync terminal=false refresh=true"
  exit 0
fi

if [ "$(uname)" = Darwin ]; then
  synced_at=$(stat -f %m "$PRICES_FILE")
else
  synced_at=$(stat -c %Y "$PRICES_FILE")
fi
age=$(($(date +%s) - synced_at))
if [ "$age" -lt 3600 ]; then
  ago="$((age / 60))m ago"
elif [ "$age" -lt 172800 ]; then
  ago="$((age / 3600))h ago"
else
  ago="$((age / 86400))d ago"
fi
if [ "$sync_failed" -eq 1 ]; then
  synced="Offline, prices from $ago"
else
  synced="Prices synced $ago"
fi

mode=$(cat "$MODE_FILE" 2>/dev/null || true)
mine=$(cat "$MINE_FILE" 2>/dev/null || true)

awk -F'\t' \
  -v self="$0" -v mode="${mode:-turn}" -v mine="$mine" -v max="$MAX_SHOWN" \
  -v tin="$TURN_IN" -v tout="$TURN_OUT" -v models_file="$MODELS_FILE" \
  -v synced="$synced" -v gray="$GRAY" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function num(v) { return v == int(v) ? sprintf("%d", v) : sprintf("%.2f", v) }
function money(c) { return c < 0.01 ? "<$0.01" : sprintf("$%.2f", c) }
function value(k) {
  if (mode == "x") return sprintf("%.1fx", costs[k] / cheapest)
  if (mode == "perm") return "$" num(ins[k]) "/" num(outs[k])
  return money(costs[k])
}
function bar(c,   w, s, j) {
  w = int(c / top * 8 + 0.5); if (w < 1) w = 1
  s = ""; for (j = 1; j <= 8; j++) s = s (j <= w ? "█" : "░")
  return s
}
function clip(s, w) { return length(s) > w ? substr(s, 1, w - 2) ".." : s }
function swap(a, b,   t) {
  t = ids[a]; ids[a] = ids[b]; ids[b] = t
  t = names[a]; names[a] = names[b]; names[b] = t
  t = ins[a]; ins[a] = ins[b]; ins[b] = t
  t = outs[a]; outs[a] = outs[b]; outs[b] = t
  t = costs[a]; costs[a] = costs[b]; costs[b] = t
}
function action(params) { return "bash=\"" self "\" " params " terminal=false refresh=true" }

FNR == NR {
  if (FNR > 1) { pname[$1] = $2; pin[$1] = $3 + 0; pout[$1] = $4 + 0; porder[++np] = $1 }
  next
}
{
  line = $0; sub(/#.*/, "", line); line = trim(line)
  if (line == "" || n >= max) next
  if (index(line, "|") > 0) {
    if (split(line, p, "|") != 3 || trim(p[1]) == "" || p[2] + 0 <= 0 || p[3] + 0 <= 0) { bad[++nbad] = line; next }
    id = "custom:" trim(p[1]); nm = trim(p[1]); i = p[2] + 0; o = p[3] + 0
  } else if (line in pname) {
    id = line; nm = pname[line]; i = pin[line]; o = pout[line]
  } else { bad[++nbad] = line; next }
  if (id in seen) next
  seen[id] = 1
  n++; ids[n] = id; names[n] = nm; ins[n] = i; outs[n] = o
  costs[n] = (i * tin + o * tout) / 1000000
}
END {
  for (a = 2; a <= n; a++) for (b = a; b > 1 && costs[b] > costs[b - 1]; b--) swap(b, b - 1)

  if (n == 0) {
    print "Model cost"
    print "---"
    print "No models selected | color=" gray
  } else {
    m = 1; for (k = 1; k <= n; k++) if (ids[k] == mine) m = k
    top = costs[1]; cheapest = costs[n]
    print names[m] " " value(m)
    print "---"
    if (mode == "x") caption = "Times the cheapest shown, per turn"
    else if (mode == "perm") caption = "$ per 1M tokens, input/output"
    else caption = "$ per turn: " tin / 1000 "K in + " tout / 1000 "K out"
    print caption " | size=11 color=" gray
    for (k = 1; k <= n; k++) {
      printf "%-16s %s %10s | font=Menlo size=12 %s%s\n", clip(names[k], 16), bar(costs[k]), value(k),
        action("param1=mine param2=\"" ids[k] "\""), (k == m ? " checked=true" : "")
    }
  }
  for (b = 1; b <= nbad; b++) { gsub(/\|/, "/", bad[b]); print "Skipped: " bad[b] " | size=11 color=" gray }

  print "---"
  print "Show as"
  print "--$ per turn | " action("param1=mode param2=turn") (mode != "x" && mode != "perm" ? " checked=true" : "")
  print "--Times the cheapest | " action("param1=mode param2=x") (mode == "x" ? " checked=true" : "")
  print "--$ per 1M tokens | " action("param1=mode param2=perm") (mode == "perm" ? " checked=true" : "")
  print "Add a model"
  if (n >= max) print "--" max " max. Remove one first. | color=" gray
  else for (k = 1; k <= np; k++) if (!(porder[k] in seen)) {
    c = (pin[porder[k]] * tin + pout[porder[k]] * tout) / 1000000
    print "--" pname[porder[k]] "  " money(c) " | " action("param1=add param2=\"" porder[k] "\"")
  }
  if (n > 0) {
    print "Remove a model"
    for (k = 1; k <= n; k++) print "--" names[k] " | " action("param1=remove param2=\"" ids[k] "\"")
  }
  print "Edit list... | bash=/usr/bin/open param1=-t param2=\"" models_file "\" terminal=false"
  print "---"
  print "Sync prices now | " action("param1=sync")
  print synced " | size=11 color=" gray
}' "$PRICES_FILE" "$MODELS_FILE"
