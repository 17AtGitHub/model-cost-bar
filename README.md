# model-cost-bar

See what each AI model costs per prompt, in your Mac menu bar, before you pick one.

Cursor, Claude, and Codex hide model prices until the bill or the budget alert arrives. This puts your model and its price in the menu bar, with up to 10 models to compare one click away.

```
Opus 5.5 $0.60                       <- menu bar: your model, cost per turn
──────────────────────────────────
  $ per turn: 100K in + 10K out
  Fable 5.1        ████████      $1.50
✓ Opus 5.5         ███░░░░░      $0.60
  GPT-5.6 Terra    ██░░░░░░      $0.32
  Grok 4.7         █░░░░░░░      $0.26
──────────────────────────────────
Show as            ›  $ per turn / Times the cheapest / $ per 1M tokens
Edit models…
──────────────────────────────────
Sync prices now
Prices synced 2h ago
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/17AtGitHub/model-cost-bar/main/install.sh | bash
```

Or from a clone: `git clone https://github.com/17AtGitHub/model-cost-bar && cd model-cost-bar && ./install.sh`

The script installs [SwiftBar](https://swiftbar.app) with Homebrew if you don't have it, then adds the plugin. It's a single shell script, so you can read all of it.

## Use

- **Panel** sits on the right of the screen while Cursor, Claude, or Codex is in front, including full screen. Claude Code and Codex in Terminal, iTerm, Warp, or Ghostty count too. Click a row to pick your model. Switch it under **Panel** to Always or Off.
- **Click a model** in the menu to make it yours. It gets a check mark and shows in the menu bar.
- **Show as** switches between dollars per turn, times the cheapest model shown, and raw $ per 1M input/output tokens.
- **Edit models…** opens a small window that stays open. Minus removes a model, plus adds one, and the menu bar updates behind it. Up to 10 are shown, most expensive first.
- **Custom model…** in that window opens `~/.config/model-cost/models`. Add a model that isn't in the list as a line like `My Model | 3 | 15`, meaning $3 per 1M input tokens and $15 per 1M output tokens.

## Where prices come from

A GitHub Action runs once a day. It reads [LiteLLM's public price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json), keeps the models in [`curated.tsv`](curated.tsv), and commits [`prices.tsv`](prices.tsv) when anything changes. The plugin downloads that file at most once a day, or when you click **Sync prices now**, and keeps the last copy for when you're offline.

Prices are the providers' list prices. What you pay through Cursor, Claude, or Codex plans can differ.

**What's a "turn"?** One agent request, estimated as 100K input tokens and 10K output tokens. Real turns vary a lot, and cached input is cheaper, so use it to compare models, not to predict your bill.

To add a model to the supported list, open a PR adding its LiteLLM key and a display name to `curated.tsv`.

## Uninstall

```sh
if [ -f ~/.cache/model-cost/float.pid ]; then kill "$(cat ~/.cache/model-cost/float.pid)" 2>/dev/null || true; fi
rm "$(defaults read com.ameba.SwiftBar PluginDirectory)/model-cost.1h.sh"
rm -rf ~/.config/model-cost ~/.cache/model-cost
```

## License

MIT
