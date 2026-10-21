#!/usr/bin/env bash
# <xbar.title>Model Cost</xbar.title>
# <xbar.version>v0.4.1</xbar.version>
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
FLOAT_MODE_FILE="$CONFIG_DIR/float-mode"
FLOAT_PID="$CACHE_DIR/float.pid"
FLOAT_VER_FILE="$CACHE_DIR/float.version"
FLOAT_VERSION=2
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

start_float() {
  [ "$(uname)" = Darwin ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  local pid="" ver=""
  [ -f "$FLOAT_PID" ] && pid=$(cat "$FLOAT_PID" 2>/dev/null || true)
  [ -f "$FLOAT_VER_FILE" ] && ver=$(cat "$FLOAT_VER_FILE" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$ver" = "$FLOAT_VERSION" ]; then
    return 0
  fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.2
  fi
  nohup "$0" float >/dev/null 2>&1 &
  disown || true
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
  floatmode) printf '%s\n' "${2:-apps}" >"$FLOAT_MODE_FILE"; exit 0 ;;
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
    edit_js="$CACHE_DIR/edit.js"
    edit_log="$CACHE_DIR/edit.log"
    cat >"$edit_js" <<'EOF'
ObjC.import("Cocoa");

var editorWindow;
var clickDelegate;
var windowDelegate;
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

function track(cost, low, high) {
  var width = 10;
  var frac = high > low ? (cost - low) / (high - low) : 0.5;
  var pos = Math.round(frac * (width - 1));
  var line = "";
  for (var i = 0; i < width; i++) line += i < pos ? "─" : (i === pos ? "●" : " ");
  return line;
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
    var model = {
      id: parts[0], name: parts[1], inn: Number(parts[2]), out: Number(parts[3]),
      score: parts[4] ? Number(parts[4]) : 0
    };
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
  var low = null;
  var high = null;
  data.shown.concat(data.available).forEach(function (model) {
    var cost = turnCost(model);
    if (low === null || cost < low) low = cost;
    if (high === null || cost > high) high = cost;
  });
  var y = 14;

  if (data.shown.length === 0) {
    label("None yet", 16, y, 250, 13, $.NSColor.secondaryLabelColor, false);
    y += 32;
  }
  data.shown.forEach(function (model, index) {
    label(model.name, 16, y, 108, 13, null, false);
    label(track(turnCost(model), low, high), 126, y, 84, 12, $.NSColor.secondaryLabelColor, true);
    label(model.score > 0 ? model.score.toFixed(1) : "", 214, y, 40, 12, $.NSColor.secondaryLabelColor, true);
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
      label(model.name, 16, y, 108, 13, null, false);
      label(track(turnCost(model), low, high), 126, y, 84, 12, $.NSColor.secondaryLabelColor, true);
      label(model.score > 0 ? model.score.toFixed(1) : "", 214, y, 40, 12, $.NSColor.secondaryLabelColor, true);
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

function fail(message) {
  try {
    var alert = $.NSAlert.alloc.init;
    alert.setMessageText("Couldn't open Models");
    alert.setInformativeText(String(message));
    alert.runModal();
  } catch (ignored) {}
}

function run() {
  try {
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSActivationPolicyRegular);
  clickDelegate = $.MCBClickDelegate.alloc.init;
  windowDelegate = $.MCBWindowDelegate.alloc.init;

  var style = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable;
  editorWindow = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 320, 480),
    style,
    $.NSBackingStoreBuffered,
    false
  );
  editorWindow.setTitle("Models");
  editorWindow.setLevel($.NSFloatingWindowLevel);
  editorWindow.setHidesOnDeactivate(false);
  editorWindow.setReleasedWhenClosed(false);
  editorWindow.setDelegate(windowDelegate);

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
  } catch (error) {
    fail(error);
  }
}
EOF
    MCB_PRICES="$PRICES_FILE" MCB_MODELS="$MODELS_FILE" MCB_PLUGIN="$plugin_path" \
      MCB_MAX="$MAX_SHOWN" MCB_TURN_IN="$TURN_IN" MCB_TURN_OUT="$TURN_OUT" \
      nohup /usr/bin/osascript -l JavaScript "$edit_js" >>"$edit_log" 2>&1 &
    disown || true
    exit 0
    ;;
  float)
    if ! command -v osascript >/dev/null 2>&1; then
      echo "The panel runs on macOS." >&2
      exit 1
    fi
    echo $$ >"$FLOAT_PID"
    echo "$FLOAT_VERSION" >"$FLOAT_VER_FILE"
    case "$0" in
      /*) plugin_path="$0" ;;
      *) plugin_path="$PWD/$0" ;;
    esac
    MCB_PRICES="$PRICES_FILE" MCB_MODELS="$MODELS_FILE" MCB_MINE="$MINE_FILE" \
      MCB_MODE="$MODE_FILE" MCB_FLOAT="$FLOAT_MODE_FILE" MCB_PLUGIN="$plugin_path" \
      MCB_MAX="$MAX_SHOWN" MCB_TURN_IN="$TURN_IN" MCB_TURN_OUT="$TURN_OUT" \
      exec osascript -l JavaScript <<'EOF'
ObjC.import("Cocoa");

var panel;
var body;
var floatDelegate;
var shownIds = [];
var lastSig = "";

function env(name) {
  var value = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  return value ? ObjC.unwrap(value) : "";
}

var pricesPath = env("MCB_PRICES");
var modelsPath = env("MCB_MODELS");
var minePath = env("MCB_MINE");
var modePath = env("MCB_MODE");
var floatPath = env("MCB_FLOAT");
var pluginPath = env("MCB_PLUGIN");
var MAX = Number(env("MCB_MAX")) || 10;
var TURN_IN = Number(env("MCB_TURN_IN")) || 100000;
var TURN_OUT = Number(env("MCB_TURN_OUT")) || 10000;
var PANEL_W = 300;

function readText(path) {
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return text ? ObjC.unwrap(text) : "";
}

function readLine(path) {
  var line = (readText(path).split("\n")[0] || "");
  return line.replace(/^[ \t]+|[ \t]+$/g, "");
}

function fileMtime(path) {
  var err = Ref();
  var attrs = $.NSFileManager.defaultManager.attributesOfItemAtPathError(path, err);
  if (!attrs) return 0;
  var date = attrs.objectForKey("NSFileModificationDate");
  if (!date) return 0;
  return Number(date.timeIntervalSince1970);
}

function turnCost(model) {
  return (model.inn * TURN_IN + model.out * TURN_OUT) / 1000000;
}

function track(cost, low, high) {
  var width = 12;
  var frac = high > low ? (cost - low) / (high - low) : 0.5;
  var pos = Math.round(frac * (width - 1));
  var line = "";
  for (var i = 0; i < width; i++) line += i < pos ? "─" : (i === pos ? "●" : " ");
  return line;
}

function scoreText(model) {
  if (!(model.score > 0)) return "    ";
  var text = model.score.toFixed(1);
  while (text.length < 4) text = " " + text;
  return text;
}

function load() {
  var byId = {};
  readText(pricesPath).split("\n").slice(1).forEach(function (line) {
    if (!line) return;
    var parts = line.split("\t");
    if (parts.length < 4 || !parts[0] || !parts[1]) return;
    byId[parts[0]] = {
      id: parts[0], name: parts[1], inn: Number(parts[2]), out: Number(parts[3]),
      score: parts[4] ? Number(parts[4]) : 0
    };
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
  shown.sort(function (a, b) { return turnCost(b) - turnCost(a); });
  return shown;
}

function floatMode() {
  var mode = readLine(floatPath);
  return mode === "always" || mode === "off" ? mode : "apps";
}

function fit(text, width) {
  if (text.length > width) return text.substring(0, width - 1) + "…";
  while (text.length < width) text += " ";
  return text;
}

function frontApp() {
  var app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  if (!app) return "";
  var name = app.localizedName ? ObjC.unwrap(app.localizedName) : "";
  var bid = app.bundleIdentifier ? ObjC.unwrap(app.bundleIdentifier) : "";
  return (name + " " + bid).toLowerCase();
}

function codingApp(label) {
  var keys = ["cursor", "todesktop", "claude", "anthropic", "codex", "terminal", "iterm", "warp", "ghostty", "alacritty", "wezterm", "kitty"];
  for (var i = 0; i < keys.length; i++) if (label.indexOf(keys[i]) >= 0) return true;
  return false;
}

function shouldShow() {
  var mode = floatMode();
  if (mode === "off") return false;
  if (mode === "always") return true;
  return codingApp(frontApp());
}

function runTask(path, args) {
  var task = $.NSTask.alloc.init;
  task.setExecutableURL($.NSURL.fileURLWithPath(path));
  var list = $.NSMutableArray.alloc.init;
  args.forEach(function (arg) { list.addObject(String(arg)); });
  task.setArguments(list);
  task.setStandardOutput($.NSFileHandle.fileHandleWithNullDevice);
  task.setStandardError($.NSFileHandle.fileHandleWithNullDevice);
  var err = Ref();
  if (!task.launchAndReturnError(err)) return;
}

function place() {
  var mouse = $.NSEvent.mouseLocation;
  var screens = $.NSScreen.screens;
  var screen = $.NSScreen.mainScreen;
  for (var i = 0; i < screens.count; i++) {
    var candidate = screens.objectAtIndex(i);
    var frame = candidate.frame;
    var origin = frame.origin;
    var size = frame.size;
    if (mouse.x >= origin.x && mouse.x <= origin.x + size.width && mouse.y >= origin.y && mouse.y <= origin.y + size.height) {
      screen = candidate;
      break;
    }
  }
  var visible = screen.visibleFrame;
  var height = panel.frame.size.height;
  var x = visible.origin.x + visible.size.width - PANEL_W - 12;
  var y = visible.origin.y + Math.max(12, (visible.size.height - height) / 2);
  panel.setFrameOrigin($.NSMakePoint(x, y));
}

function rebuild() {
  var views = body.subviews;
  var old = [];
  for (var i = 0; i < views.count; i++) old.push(views.objectAtIndex(i));
  old.forEach(function (view) { view.removeFromSuperview; });

  var shown = load();
  shownIds = shown.map(function (model) { return model.id; });
  if (shown.length === 0) {
    panel.setContentSize($.NSMakeSize(PANEL_W, 36));
    return;
  }
  var mine = readLine(minePath);
  var low = turnCost(shown[shown.length - 1]);
  var high = turnCost(shown[0]);
  var font = $.NSFont.fontWithNameSize("Menlo", 11);
  if (!font) font = $.NSFont.monospacedSystemFontOfSizeWeight(11, $.NSFontWeightRegular);
  var y = 6;
  var header = $.NSTextField.labelWithString(fit("", 16) + " " + fit("cost →", 12) + " coding");
  header.setFrame($.NSMakeRect(8, y, PANEL_W - 16, 16));
  header.setFont(font);
  header.setTextColor($.NSColor.secondaryLabelColor);
  body.addSubview(header);
  y += 18;
  shown.forEach(function (model, index) {
    var button = $.NSButton.alloc.initWithFrame($.NSMakeRect(8, y, PANEL_W - 16, 22));
    var title = fit(model.name, 16) + " " + track(turnCost(model), low, high) + " " + scoreText(model);
    button.setTitle(title);
    button.setFont(font);
    button.setBordered(false);
    button.setAlignment($.NSTextAlignmentLeft);
    button.setContentTintColor(model.id === mine || (mine === "" && index === 0)
      ? $.NSColor.controlAccentColor
      : $.NSColor.labelColor);
    button.setTag(index);
    button.setTarget(floatDelegate);
    button.setAction("onPick:");
    body.addSubview(button);
    y += 24;
  });
  var height = y + 6;
  panel.setContentSize($.NSMakeSize(PANEL_W, height));
  body.setFrame($.NSMakeRect(0, 0, PANEL_W, height));
}

function tick() {
  if (!shouldShow() || !readText(pricesPath)) {
    if (panel.isVisible) panel.orderOut(null);
    return;
  }
  var sig = [fileMtime(pricesPath), fileMtime(modelsPath), fileMtime(minePath), fileMtime(floatPath), readLine(minePath)].join(":");
  if (sig !== lastSig) {
    rebuild();
    lastSig = sig;
    if (load().length === 0) {
      panel.orderOut(null);
      return;
    }
    place();
  }
  if (!panel.isVisible) {
    place();
    panel.orderFrontRegardless();
  }
}

ObjC.registerSubclass({
  name: "MCBFloatDelegate",
  superclass: "NSObject",
  methods: {
    "tick:": { types: ["v", ["@"]], implementation: function () { tick(); } },
    "onPick:": {
      types: ["v", ["@"]],
      implementation: function (sender) {
        var id = shownIds[Number(sender.tag)];
        if (!id) return;
        var text = $.NSString.alloc.initWithString(id + "\n");
        text.writeToFileAtomicallyEncodingError(minePath, true, $.NSUTF8StringEncoding, null);
        runTask("/usr/bin/open", ["-g", "swiftbar://refreshplugin?name=model-cost.1h.sh"]);
        floatDelegate.performSelectorWithObjectAfterDelay("tick:", null, 0.05);
      }
    }
  }
});

ObjC.registerSubclass({
  name: "MCBFloatBody",
  superclass: "NSView",
  methods: {
    isFlipped: { types: ["B", []], implementation: function () { return true; } }
  }
});

function run() {
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSActivationPolicyAccessory);
  floatDelegate = $.MCBFloatDelegate.alloc.init;

  panel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, PANEL_W, 80),
    $.NSWindowStyleMaskBorderless | $.NSWindowStyleMaskNonactivatingPanel,
    $.NSBackingStoreBuffered,
    false
  );
  panel.setLevel($.NSStatusWindowLevel);
  panel.setCollectionBehavior(
    $.NSWindowCollectionBehaviorCanJoinAllSpaces |
    $.NSWindowCollectionBehaviorFullScreenAuxiliary |
    $.NSWindowCollectionBehaviorStationary |
    $.NSWindowCollectionBehaviorIgnoresCycle
  );
  panel.setFloatingPanel(true);
  panel.setHidesOnDeactivate(false);
  panel.setBecomesKeyOnlyIfNeeded(true);
  panel.setOpaque(false);
  panel.setBackgroundColor($.NSColor.clearColor);
  panel.setHasShadow(true);
  panel.setAppearance($.NSAppearance.appearanceNamed($.NSAppearanceNameDarkAqua));

  var effect = $.NSVisualEffectView.alloc.initWithFrame($.NSMakeRect(0, 0, PANEL_W, 80));
  effect.setMaterial($.NSVisualEffectMaterialHUDWindow);
  effect.setBlendingMode($.NSVisualEffectBlendingModeBehindWindow);
  effect.setState($.NSVisualEffectStateActive);
  effect.setWantsLayer(true);
  effect.layer.setCornerRadius(12);
  effect.layer.setMasksToBounds(true);
  panel.setContentView(effect);

  body = $.MCBFloatBody.alloc.initWithFrame($.NSMakeRect(0, 0, PANEL_W, 80));
  body.setAutoresizingMask($.NSViewWidthSizable | $.NSViewHeightSizable);
  effect.addSubview(body);

  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.7, floatDelegate, "tick:", null, true);
  app.run();
}
EOF
esac

sync_failed=0
start_float
if [ ! -s "$PRICES_FILE" ] || [ -z "$(find "$PRICES_FILE" -mmin -"$SYNC_EVERY_MIN" 2>/dev/null)" ] || ! head -1 "$PRICES_FILE" | grep -q 'score'; then
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

mine=$(cat "$MINE_FILE" 2>/dev/null || true)
float_mode=$(cat "$FLOAT_MODE_FILE" 2>/dev/null || true)
case "$float_mode" in
  always | off) ;;
  *) float_mode=apps ;;
esac

awk -F'\t' \
  -v self="$0" -v mine="$mine" -v max="$MAX_SHOWN" \
  -v tin="$TURN_IN" -v tout="$TURN_OUT" -v float_mode="$float_mode" \
  -v synced="$synced" -v gray="$GRAY" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function clip(s, w) { return length(s) > w ? substr(s, 1, w - 2) ".." : s }
function track(c, width,   frac, pos, s, j) {
  frac = (top == cheapest) ? 0.5 : (c - cheapest) / (top - cheapest)
  pos = int(frac * (width - 1) + 0.5)
  s = ""
  for (j = 0; j < width; j++) s = s (j < pos ? "─" : (j == pos ? "●" : " "))
  return s
}
function scoretext(k) { return scores[k] == "" ? "    " : sprintf("%4.1f", scores[k]) }
function swap(a, b,   t) {
  t = ids[a]; ids[a] = ids[b]; ids[b] = t
  t = names[a]; names[a] = names[b]; names[b] = t
  t = ins[a]; ins[a] = ins[b]; ins[b] = t
  t = outs[a]; outs[a] = outs[b]; outs[b] = t
  t = costs[a]; costs[a] = costs[b]; costs[b] = t
  t = scores[a]; scores[a] = scores[b]; scores[b] = t
}
function action(params) { return "bash=\"" self "\" " params " terminal=false refresh=true" }

FNR == NR {
  if (FNR > 1) {
    pname[$1] = $2; pin[$1] = $3 + 0; pout[$1] = $4 + 0
    pscore[$1] = ($5 == "" ? "" : $5 + 0)
    porder[++np] = $1
  }
  next
}
{
  line = $0; sub(/#.*/, "", line); line = trim(line)
  if (line == "" || n >= max) next
  if (index(line, "|") > 0) {
    if (split(line, p, "|") != 3 || trim(p[1]) == "" || p[2] + 0 <= 0 || p[3] + 0 <= 0) { bad[++nbad] = line; next }
    id = "custom:" trim(p[1]); nm = trim(p[1]); i = p[2] + 0; o = p[3] + 0; sc = ""
  } else if (line in pname) {
    id = line; nm = pname[line]; i = pin[line]; o = pout[line]; sc = pscore[line]
  } else { bad[++nbad] = line; next }
  if (id in seen) next
  seen[id] = 1
  n++; ids[n] = id; names[n] = nm; ins[n] = i; outs[n] = o; scores[n] = sc
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
    print names[m] "  " track(costs[m], 7)
    print "---"
    printf "%-16s %-12s %s | size=11 color=%s\n", "", "cost →", "coding", gray
    for (k = 1; k <= n; k++) {
      printf "%-16s %s %s | font=Menlo size=12 %s%s\n", clip(names[k], 16), track(costs[k], 12), scoretext(k),
        action("param1=mine param2=\"" ids[k] "\""), (k == m ? " checked=true" : "")
    }
  }
  for (b = 1; b <= nbad; b++) { gsub(/\|/, "/", bad[b]); print "Skipped: " bad[b] " | size=11 color=" gray }

  print "---"
  print "Edit models… | sfimage=square.and.pencil " action("param1=edit")
  print "Panel"
  print "--Cursor, Claude, Codex | " action("param1=floatmode param2=apps") (float_mode == "apps" ? " checked=true" : "")
  print "--Always | " action("param1=floatmode param2=always") (float_mode == "always" ? " checked=true" : "")
  print "--Off | " action("param1=floatmode param2=off") (float_mode == "off" ? " checked=true" : "")
  print "---"
  print "Sync prices now | " action("param1=sync")
  print synced " | size=11 color=" gray
}' "$PRICES_FILE" "$MODELS_FILE"
