"""Builds prices.tsv from LiteLLM's public price list, keeping only the models in curated.tsv."""

import csv
import json
import sys
import urllib.request
from pathlib import Path

LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
ROOT = Path(__file__).resolve().parent.parent


def per_million(cost_per_token: float) -> str:
    return f"{round(cost_per_token * 1_000_000, 4):g}"


def main() -> None:
    with urllib.request.urlopen(LITELLM_URL, timeout=30) as resp:
        prices = json.load(resp)

    with open(ROOT / "curated.tsv", newline="") as f:
        curated = list(csv.DictReader(f, delimiter="\t"))

    rows, missing = [], []
    for model in curated:
        entry = prices.get(model["id"], {})
        cost_in, cost_out = entry.get("input_cost_per_token"), entry.get("output_cost_per_token")
        if cost_in is None or cost_out is None:
            missing.append(model["id"])
            continue
        rows.append([model["id"], model["name"], per_million(cost_in), per_million(cost_out)])

    if missing:
        print(f"warning: not in LiteLLM price list: {', '.join(missing)}", file=sys.stderr)
    if not rows:
        sys.exit("error: none of the curated models have prices")

    with open(ROOT / "prices.tsv", "w", newline="") as f:
        writer = csv.writer(f, delimiter="\t", lineterminator="\n")
        writer.writerow(["id", "name", "input_per_m", "output_per_m"])
        writer.writerows(rows)
    print(f"wrote {len(rows)} models to prices.tsv")


if __name__ == "__main__":
    main()
