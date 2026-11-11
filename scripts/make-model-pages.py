#!/usr/bin/env python3
"""Writes the model pages of the project site (docs/models/) from FixStat's own data:
SensorMaps/sensor-map.json (named sensors per model), SensorMaps/parts.json (values of genuine
batteries and power adapters), the README's verified models table (Mac names, chips, boards) and
the English sensor names of App/Localizable.xcstrings. Run it after a merge; it changes nothing
else. No dependencies beyond Python 3.

    python3 scripts/make-model-pages.py
"""
import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = "https://lapsely.github.io/fixstat/"
OUT = os.path.join(ROOT, "docs", "models")

# Models with parts data but no row in the README table (no sensor map yet).
EXTRA_NAMES = {
    "Mac17,3": ("MacBook Air (13-inch, M5)", "Apple M5", None),
    "MacBookAir7,2": ("MacBook Air (13-inch, Early 2015 / 2017)", "Intel Core (Broadwell)", None),
    "MacBookAir8,2": ("MacBook Air (Retina, 13-inch, 2019)", "Intel Core (Amber Lake)", None),
    "MacBookAir9,1": ("MacBook Air (Retina, 13-inch, 2020)", "Intel Core (Ice Lake)", None),
    "MacBookPro13,2": ("MacBook Pro (13-inch, 2016, four Thunderbolt 3 ports)", "Intel Core (Skylake)", None),
    "MacBookPro14,1": ("MacBook Pro (13-inch, 2017, two Thunderbolt 3 ports)", "Intel Core (Kaby Lake)", None),
}

GROUPS = [("cpu", "CPU"), ("gpu", "GPU"), ("ssd", "SSD"), ("battery", "Battery"),
          ("chassis", "Enclosure"), ("other", "Board and other")]


def load(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return json.load(f)


def readme_models():
    """Model identifier → (Mac, chip, board) from the README's verified models table."""
    rows = {}
    with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|", line)
            if m:
                board = m.group(4) if m.group(4) not in ("–", "-") else None
                rows[m.group(1)] = (m.group(2), m.group(3), board)
    return rows


def english_names():
    strings = load("App/Localizable.xcstrings")["strings"]
    names = {}
    for key, entry in strings.items():
        if key.startswith("sensor."):
            value = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
            if value:
                names[key] = value
    return names


def sensor_name(sensor_id, names):
    if "sensor." + sensor_id in names:
        return names["sensor." + sensor_id]
    parts = sensor_id.split(".")
    if parts[-1].isdigit():
        fmt = names.get("sensor." + ".".join(parts[:-1]) + ".n")
        if fmt:
            return fmt.replace("%lld", parts[-1])
    return sensor_id


def slug(model):
    return model.lower().replace(",", "-")


def e(text):
    return html.escape(str(text), quote=True)


STYLE = """
  :root { --bg: #fbfbfd; --surface: #ffffff; --text: #1d1d1f; --muted: #5f6368; --line: #e3e3e8;
          --accent: #0a66d8; --code: #f2f2f5; --ok: #1f7a3a; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #111214; --surface: #1b1c1f; --text: #f2f2f4; --muted: #a3a6ad; --line: #2c2e33;
            --accent: #3d8bff; --code: #24262a; --ok: #4cc27a; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
         font: 16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif; }
  .wrap { max-width: 980px; margin: 0 auto; padding: 0 16px; }
  header { padding: 40px 0 16px; }
  nav { font-size: 14px; color: var(--muted); }
  nav a, a { color: var(--accent); }
  h1 { font-size: 32px; line-height: 1.15; margin: 10px 0 6px; letter-spacing: -0.01em; }
  h2 { font-size: 21px; margin: 32px 0 10px; }
  .lead { color: var(--muted); margin: 0 0 8px; }
  .facts { display: flex; flex-wrap: wrap; gap: 8px 22px; margin: 14px 0 4px; font-size: 15px; }
  .facts span { color: var(--muted); }
  .card { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 4px 16px; overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 15px; }
  th, td { text-align: left; padding: 8px 10px 8px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  th { color: var(--muted); font-weight: 600; font-size: 13px; }
  code { background: var(--code); padding: 1px 6px; border-radius: 5px; font-size: 0.9em; }
  .ok { color: var(--ok); }
  .muted { color: var(--muted); }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
  .grid a { display: block; background: var(--surface); border: 1px solid var(--line); border-radius: 12px;
            padding: 14px 16px; text-decoration: none; color: var(--text); }
  .grid a strong { display: block; }
  .grid a span { color: var(--muted); font-size: 14px; }
  footer { border-top: 1px solid var(--line); margin-top: 48px; padding: 24px 0 40px; color: var(--muted); font-size: 14px; }
  footer a { color: var(--muted); }
"""


def page(title, description, canonical, body):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(description)}">
<link rel="canonical" href="{e(canonical)}">
<link rel="icon" href="../icon.png">
<style>{STYLE}</style>
</head>
<body>
<div class="wrap">
{body}
</div>
<footer>
  <div class="wrap">
    Generated from FixStat's sensor map and parts data, measured on the bench with FixStat.
    · <a href="../">FixStat</a>
    · <a href="https://github.com/Lapsely/fixstat">GitHub</a>
    · <a href="https://github.com/Lapsely/fixstat/releases/latest/download/FixStat.dmg">Download</a>
  </div>
</footer>
</body>
</html>
"""


def battery_section(battery):
    rows = [("Design capacity", " / ".join(f"{c} mAh" for c in battery.get("designCapacity", []))),
            ("Gauge", ", ".join(battery.get("gauges", []))),
            ("Cells in series", battery.get("cellCount")),
            ("Chemistry IDs", ", ".join(str(c) for c in battery.get("chemistryIDs", []))),
            ("Cell makers", ", ".join(battery.get("cellVendors", []))),
            ("Genuine packs seen", battery.get("samples"))]
    cells = "".join(f"<tr><th>{e(k)}</th><td>{e(v)}</td></tr>" for k, v in rows if v not in (None, ""))
    return ("<h2>Genuine battery</h2>\n<p class=\"lead\">Values of original Apple packs recorded at the bench. "
            "FixStat's originality check compares a pack with them (a consistency check, not proof).</p>\n"
            f"<div class=\"card\"><table>{cells}</table></div>")


def sensor_section(entry, names):
    sensors = entry.get("sensors", [])
    blocks = []
    for group, title in GROUPS:
        items = sorted((s for s in sensors if s.get("group") == group), key=lambda s: s["id"])
        if not items:
            continue
        rows = []
        for s in items:
            source = f"<code>{e(s['key'])}</code>"
            if s.get("hidName"):
                source += f" <span class=\"muted\">HID “{e(s['hidName'])}”</span>"
            state = '<span class="ok">verified by test</span>' if s.get("confidence") == "verified" else '<span class="muted">estimated</span>'
            rows.append(f"<tr><td>{e(sensor_name(s['id'], names))}</td><td>{source}</td><td>{state}</td></tr>")
        blocks.append(f"<h3>{e(title)}</h3>\n<div class=\"card\"><table><tr><th>Sensor</th><th>SMC key</th><th>Naming</th></tr>"
                      + "".join(rows) + "</table></div>")
    ignored = len(entry.get("ignored", [])) + len(entry.get("derived", []))
    note = (f"<p class=\"muted\">{ignored} more keys are constant, unpopulated or aggregates of other sensors; "
            "FixStat lists them only in raw lists.</p>") if ignored else ""
    return ("<h2>Temperature sensors</h2>\n<p class=\"lead\">Names from load tests on the bench (CPU, GPU, SSD, charger): "
            "“verified by test” sensors followed the matching load; the others are named from the chip and key patterns.</p>\n"
            + "\n".join(blocks) + note)


def main():
    sensor_map = load("SensorMaps/sensor-map.json")
    parts = load("SensorMaps/parts.json")
    names = english_names()
    table = readme_models()
    table.update({k: v for k, v in EXTRA_NAMES.items() if k not in table})
    models = sorted(set(sensor_map["models"]) | set(parts["batteries"]))
    os.makedirs(OUT, exist_ok=True)

    cards = []
    for model in models:
        mac, chip, board = table.get(model, (model, sensor_map["models"].get(model, {}).get("chip", ""), None))
        entry = sensor_map["models"].get(model)
        battery = parts["batteries"].get(model)
        count = len(entry["sensors"]) if entry else 0
        verified = sum(1 for s in entry["sensors"] if s.get("confidence") == "verified") if entry else 0
        board = board or (entry or {}).get("board")
        facts = [("Model identifier", f"<code>{e(model)}</code>"), ("Chip", e(chip))]
        if board:
            facts.append(("Board", e(board)))
        if entry:
            facts.append(("Sensors named", f"{count} ({verified} verified by test)"))
        body = (f"<header><nav><a href=\"../\">FixStat</a> › <a href=\"./\">Mac models</a></nav>\n"
                f"<h1>{e(mac)}</h1>\n<p class=\"lead\">Temperature sensors and genuine parts of the {e(mac)} "
                f"(<code>{e(model)}</code>), as FixStat reads them.</p>\n<div class=\"facts\">"
                + "".join(f"<div><span>{k}</span> {v}</div>" for k, v in facts) + "</div></header>\n")
        if entry:
            body += sensor_section(entry, names) + "\n"
        else:
            body += ("<h2>Temperature sensors</h2>\n<p class=\"lead\">No sensor map for this model yet: FixStat names its "
                     "sensors from the chip and key patterns. Bench recordings of a healthy unit add it.</p>\n")
        if battery:
            body += battery_section(battery) + "\n"
        description = (f"{mac} ({model}): " + (f"{count} temperature sensors with their SMC keys and names, " if entry else "")
                       + ("genuine battery values (design capacity, gauge, chemistry, cell makers), " if battery else "")
                       + "measured on the bench with FixStat, a free Mac diagnostics app for repair technicians.")
        url = SITE + f"models/{slug(model)}.html"
        with open(os.path.join(OUT, slug(model) + ".html"), "w", encoding="utf-8") as f:
            f.write(page(f"{mac} ({model}): sensors and genuine parts – FixStat", description, url, body))
        cards.append(f"<a href=\"{slug(model)}.html\"><strong>{e(mac)}</strong><span>{e(model)} · {e(chip)}"
                     + (f" · {count} sensors" if entry else "") + "</span></a>")

    adapters = sorted(parts.get("adapters", []), key=lambda a: (a.get("watts") or 0, a.get("id", "")))
    rows = []
    for a in adapters:
        profiles = ", ".join(f"{p[0] / 1000:g} V {p[1] / 1000:g} A" for p in a.get("profiles", []))
        rows.append(f"<tr><td>{e(a.get('name', ''))}</td><td><code>{e(a.get('id', ''))}</code></td>"
                    f"<td>{e(a.get('watts', ''))} W</td><td>{e(profiles)}</td><td>{e(', '.join(a.get('firmware', [])))}</td></tr>")
    body = ("<header><nav><a href=\"../\">FixStat</a> › Mac models</nav>\n<h1>Mac models</h1>\n"
            "<p class=\"lead\">Temperature sensor names with their SMC keys, and the values of genuine batteries and power "
            "adapters, recorded on the bench with FixStat.</p></header>\n<div class=\"grid\">" + "".join(cards) + "</div>\n"
            "<h2>Genuine Apple power adapters</h2>\n<p class=\"lead\">The adapter ID, power profiles and firmware that "
            "original adapters report; FixStat compares a connected adapter with them.</p>\n"
            "<div class=\"card\"><table><tr><th>Adapter</th><th>ID</th><th>Reported</th><th>Profiles</th><th>Firmware</th></tr>"
            + "".join(rows) + "</table></div>")
    with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as f:
        f.write(page("Mac models: temperature sensors, SMC keys and genuine parts – FixStat",
                     "Temperature sensor names and SMC keys per Mac model, and values of genuine Apple batteries and power "
                     "adapters, measured on the bench with FixStat.", SITE + "models/", body))

    urls = [SITE, SITE + "models/"] + [SITE + f"models/{slug(m)}.html" for m in models]
    with open(os.path.join(ROOT, "docs", "sitemap.xml"), "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                + "".join(f"  <url><loc>{u}</loc></url>\n" for u in urls) + "</urlset>\n")
    print(f"wrote {len(models)} model pages, the index and docs/sitemap.xml")


if __name__ == "__main__":
    sys.exit(main())
