#!/usr/bin/env bash
# <xbar.title>Model Cost</xbar.title>
# <xbar.version>v0.2.0</xbar.version>
# <xbar.author>Daksh Kochhar</xbar.author>
# <xbar.author.github>17AtGitHub</xbar.author.github>
# <xbar.desc>Shows what each AI model costs per prompt, so you can pick before you spend.</xbar.desc>
# <xbar.dependencies>bash,curl,awk,osascript</xbar.dependencies>
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
MAX_SHOWN=10
SYNC_EVERY_MIN=1440
GRAY="#8E8E93"

mkdir -p "$CONFIG_DIR" "$CACHE_DIR"

if [ ! -f "$MODELS_FILE" ]; then
  cat >"$MODELS_FILE" <<'EOF'
# Models shown in the menu bar. The first 10 valid lines are shown, most expensive first.
# Add or remove them from "Edit models…", or add a custom model as:  Name | input $ per 1M | output $ per 1M
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
  edit)
    # A menu click always closes the menu, so add/remove happen in a window that stays open.
    if ! command -v osascript >/dev/null 2>&1; then
      echo "Edit models runs on macOS." >&2
      exit 1
    fi
    if [ ! -s "$PRICES_FILE" ]; then
      sync_prices || true
    fi
    case "$0" in
      /*) plugin_path="$0" ;;
      *) plugin_path="$PWD/$0" ;;
    esac
    MCB_PRICES="$PRICES_FILE" MCB_MODELS="$MODELS_FILE" MCB_PLUGIN="$plugin_path" \
      MCB_MAX="$MAX_SHOWN" MCB_TURN_IN="$TURN_IN" MCB_TURN_OUT="$TURN_OUT" \
      osascript -l JavaScript <<'EOF' || true
ObjC.import("Cocoa");

var editorWindow;
var clickDelegate;
var shownIds = [];
var addIds = [];
var docView;

function env(name) {
  var value = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  return value ? ObjC.unwrap(value) : "";
}

var pricesPath = env("MCB_PRICES");
var modelsPath = env("MCB_MODELS");
var pluginPath = env("MCB_PLUGIN");
var MAX = Number(env("MCB_MAX")) || 10;
var TURN_IN = Number(env("MCB_TURN_IN")) || 100000;
var TURN_OUT = Number(env("MCB_TURN_OUT")) || 10000;

function turnCost(model) {
  return (model.inn * TURN_IN + model.out * TURN_OUT) / 1000000;
}

function money(cost) {
  if (cost < 0.01) return "<$0.01";
  return "$" + (Math.round(cost * 100) / 100).toFixed(2);
}

function readText(path) {
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return text ? ObjC.unwrap(text) : "";
}

function load() {
  var byId = {};
  var catalog = [];
  readText(pricesPath).split("\n").slice(1).forEach(function (line) {
    if (!line) return;
    var parts = line.split("\t");
    if (parts.length < 4 || !parts[0] || !parts[1]) return;
    var model = { id: parts[0], name: parts[1], inn: Number(parts[2]), out: Number(parts[3]) };
    byId[model.id] = model;
    catalog.push(model);
  });

  var shown = [];
  var seen = {};
  readText(modelsPath).split("\n").forEach(function (raw) {
    var line = raw.replace(/#.*/, "").replace(/^[ \t]+|[ \t]+$/g, "");
    if (!line) return;
    var model = null;
    if (line.indexOf("|") >= 0) {
      var bits = line.split("|");
      if (bits.length !== 3) return;
      var name = bits[0].replace(/^[ \t]+|[ \t]+$/g, "");
      var inn = Number(bits[1]);
      var out = Number(bits[2]);
      if (!name || !(inn > 0) || !(out > 0)) return;
      model = { id: "custom:" + name, name: name, inn: inn, out: out };
    } else if (byId[line]) {
      model = byId[line];
    } else {
      return;
    }
    if (seen[model.id]) return;
    seen[model.id] = true;
    if (shown.length < MAX) shown.push(model);
  });

  var available = catalog.filter(function (model) { return !seen[model.id]; });
  shown.sort(function (a, b) { return turnCost(b) - turnCost(a); });
  available.sort(function (a, b) { return turnCost(b) - turnCost(a); });
  return { shown: shown, available: available };
}

function runTask(path, args, wait) {
  var task = $.NSTask.alloc.init;
  task.setExecutableURL($.NSURL.fileURLWithPath(path));
  var list = $.NSMutableArray.alloc.init;
  args.forEach(function (arg) { list.addObject(String(arg)); });
  task.setArguments(list);
  task.setStandardOutput($.NSFileHandle.fileHandleWithNullDevice);
  task.setStandardError($.NSFileHandle.fileHandleWithNullDevice);
  var err = Ref();
  if (!task.launchAndReturnError(err)) return;
  if (wait) task.waitUntilExit;
}

function label(text, x, y, width, size, color, mono) {
  var field = $.NSTextField.labelWithString(text);
  field.setFrame($.NSMakeRect(x, y, width, 20));
  field.setFont(mono
    ? $.NSFont.monospacedDigitSystemFontOfSizeWeight(size, $.NSFontWeightRegular)
    : $.NSFont.systemFontOfSize(size));
  if (color) field.setTextColor(color);
  if (mono) field.setAlignment($.NSTextAlignmentRight);
  field.setLineBreakMode($.NSLineBreakByTruncatingTail);
  docView.addSubview(field);
}

function iconButton(symbol, x, y, tag) {
  var button = $.NSButton.alloc.initWithFrame($.NSMakeRect(x, y - 2, 28, 26));
  button.setBordered(false);
  button.setButtonType($.NSButtonTypeMomentaryChange);
  button.setImage($.NSImage.imageWithSystemSymbolNameScale(symbol, $.NSImageSymbolScaleMedium));
  button.setImagePosition($.NSImageOnly);
  button.setContentTintColor($.NSColor.secondaryLabelColor);
  button.setToolTip(tag >= 1000 ? "Add" : "Remove");
  button.setTag(tag);
  button.setTarget(clickDelegate);
  button.setAction("onClick:");
  docView.addSubview(button);
}

function rebuild() {
  var views = docView.subviews;
  var old = [];
  for (var i = 0; i < views.count; i++) old.push(views.objectAtIndex(i));
  old.forEach(function (view) { view.removeFromSuperview; });

  var data = load();
  shownIds = data.shown.map(function (model) { return model.id; });
  addIds = data.available.map(function (model) { return model.id; });
  var y = 14;

  if (data.shown.length === 0) {
    label("None yet", 16, y, 250, 13, $.NSColor.secondaryLabelColor, false);
    y += 32;
  }
  data.shown.forEach(function (model, index) {
    label(model.name, 16, y, 176, 13, null, false);
    label(money(turnCost(model)), 196, y, 64, 12, $.NSColor.secondaryLabelColor, true);
    iconButton("minus.circle", 272, y, index);
    y += 32;
  });

  y += 6;
  var rule = $.NSBox.alloc.initWithFrame($.NSMakeRect(16, y, 288, 1));
  rule.setBoxType($.NSBoxSeparator);
  docView.addSubview(rule);
  y += 14;
  label("Add", 16, y, 250, 11, $.NSColor.secondaryLabelColor, false);
  y += 26;

  if (data.shown.length >= MAX) {
    label(MAX + " max", 16, y, 250, 13, $.NSColor.secondaryLabelColor, false);
    y += 32;
  } else if (data.available.length === 0) {
    label("All models added", 16, y, 250, 13, $.NSColor.secondaryLabelColor, false);
    y += 32;
  } else {
    data.available.forEach(function (model, index) {
      label(model.name, 16, y, 176, 13, null, false);
      label(money(turnCost(model)), 196, y, 64, 12, $.NSColor.secondaryLabelColor, true);
      iconButton("plus.circle", 272, y, 1000 + index);
      y += 32;
    });
  }

  var custom = $.NSButton.alloc.initWithFrame($.NSMakeRect(10, y + 4, 160, 24));
  custom.setBordered(false);
  custom.setTitle("Custom model…");
  custom.setAlignment($.NSTextAlignmentLeft);
  custom.setFont($.NSFont.systemFontOfSize(12));
  custom.setContentTintColor($.NSColor.secondaryLabelColor);
  custom.setTag(-1);
  custom.setTarget(clickDelegate);
  custom.setAction("onClick:");
  docView.addSubview(custom);
  y += 40;

  docView.setFrame($.NSMakeRect(0, 0, 320, y));
}

ObjC.registerSubclass({
  name: "MCBClickDelegate",
  superclass: "NSObject",
  methods: {
    "onClick:": {
      types: ["v", ["@"]],
      implementation: function (sender) {
        var tag = Number(sender.tag);
        if (tag === -1) {
          runTask("/usr/bin/open", ["-t", modelsPath], false);
          return;
        }
        if (tag >= 1000) runTask(pluginPath, ["add", addIds[tag - 1000]], true);
        else runTask(pluginPath, ["remove", shownIds[tag]], true);
        clickDelegate.performSelectorWithObjectAfterDelay("rebuildLater:", null, 0);
      }
    },
    "rebuildLater:": {
      types: ["v", ["@"]],
      implementation: function () {
        rebuild();
        runTask("/usr/bin/open", ["-g", "swiftbar://refreshplugin?name=model-cost.1h.sh"], false);
      }
    }
  }
});

ObjC.registerSubclass({
  name: "MCBWindowDelegate",
  superclass: "NSObject",
  protocols: ["NSWindowDelegate"],
  methods: {
    "windowWillClose:": {
      types: ["v", ["@"]],
      implementation: function () {
        $.NSApplication.sharedApplication.terminate(null);
      }
    },
    "windowDidBecomeKey:": {
      types: ["v", ["@"]],
      implementation: function () { rebuild(); }
    }
  }
});

ObjC.registerSubclass({
  name: "MCBFlippedView",
  superclass: "NSView",
  methods: {
    isFlipped: { types: ["B", []], implementation: function () { return true; } }
  }
});

function run() {
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSActivationPolicyAccessory);
  clickDelegate = $.MCBClickDelegate.alloc.init;

  var style = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable;
  editorWindow = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 320, 480),
    style,
    $.NSBackingStoreBuffered,
    false
  );
  editorWindow.setTitle("Models");
  editorWindow.setLevel($.NSFloatingWindowLevel);
  editorWindow.setReleasedWhenClosed(false);
  editorWindow.setDelegate($.MCBWindowDelegate.alloc.init);

  var scroll = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(0, 0, 320, 480));
  scroll.setHasVerticalScroller(true);
  scroll.setAutohidesScrollers(true);
  scroll.setDrawsBackground(false);
  scroll.setBorderType($.NSNoBorder);
  docView = $.MCBFlippedView.alloc.initWithFrame($.NSMakeRect(0, 0, 320, 480));
  scroll.setDocumentView(docView);
  editorWindow.setContentView(scroll);

  rebuild();
  editorWindow.center;
  editorWindow.makeKeyAndOrderFront(app);
  app.activateIgnoringOtherApps(true);
  app.run();
}
EOF
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
  -v tin="$TURN_IN" -v tout="$TURN_OUT" \
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
  print "Edit models… | sfimage=square.and.pencil " action("param1=edit")
  print "---"
  print "Sync prices now | " action("param1=sync")
  print synced " | size=11 color=" gray
}' "$PRICES_FILE" "$MODELS_FILE"
