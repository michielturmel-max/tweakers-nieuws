#!/usr/bin/env python3
# Recente video's van een YouTube-kanaal uit de VideoS-tab (ytInitialData)
# halen. Zelfde JSON-vorm als de RSS/Atom-parser in tweakers-nieuws, zodat de
# rest van de lijstmodus (cache, klik → artikelpagina) ongewijzigd werkt:
#   [{"url","title","lead","author","date","reacties"}]
# De tab is sinds kort opgebouwd met lockupViewModel-blokken; de oudere
# videoRenderer-vorm blijft ondersteund voor het geval YouTube terugschakelt.
import json
import re
import sys


def text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    runs = value.get("runs")
    if isinstance(runs, list) and runs:
        return "".join(r.get("text", "") for r in runs if r)
    return value.get("simpleText") or value.get("content") or ""


def main():
    if len(sys.argv) > 1:
        try:
            with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
                html = fh.read()
        except OSError as exc:
            print(json.dumps([], separators=(",", ":")))
            return
    else:
        html = sys.stdin.read()

    limit = 10
    if len(sys.argv) > 2:
        try:
            limit = max(1, min(int(sys.argv[2]), 50))
        except ValueError:
            limit = 10

    m = re.search(r"var ytInitialData\s*=\s*(\{.*?\})\s*;\s*</script>", html, re.S)
    if not m:
        print(json.dumps([], separators=(",", ":")))
        return
    try:
        data = json.loads(m.group(1))
    except (ValueError, TypeError):
        print(json.dumps([], separators=(",", ":")))
        return

    grid = []
    try:
        two = data["contents"]["twoColumnBrowseResultsRenderer"]
        for tab in two.get("tabs", []):
            tr = tab.get("tabRenderer") or tab.get("expandableTabRenderer") or {}
            content = tr.get("content") or {}
            if "richGridRenderer" in content:
                grid = content["richGridRenderer"].get("contents", [])
                break
            if "itemSectionRenderer" in content:
                grid = content["itemSectionRenderer"].get("contents", [])
                break
    except (KeyError, TypeError):
        grid = []

    out = []

    def push(url, title, lead, author, date):
        if not title or not url:
            return
        if len(lead) > 320:
            lead = lead[:317] + "..."
        out.append({
            "url": url, "title": title, "lead": lead,
            "author": author, "date": date, "reacties": "",
        })

    for item in grid:
        if len(out) >= limit:
            break
        if "richItemRenderer" in item:
            content = item["richItemRenderer"].get("content") or {}
            if "lockupViewModel" in content:
                lock = content["lockupViewModel"]
                vid = lock.get("contentId") or ""
                meta = lock.get("metadata") or {}
                lm = meta.get("lockupMetadataViewModel") or {}
                title = text(lm.get("title"))
                view = ""
                rel = ""
                rows = []
                cm = lm.get("metadata") or {}
                cvm = cm.get("contentMetadataViewModel") or {}
                rows = cvm.get("metadataRows") or []
                for r in rows:
                    for p in (r.get("metadataParts") or []):
                        txt = text(p.get("text"))
                        lbl = p.get("accessibilityLabel") or txt
                        if "weergave" in lbl and view == "":
                            view = lbl
                        elif rel == "" and txt != "" and "weergave" not in lbl:
                            rel = txt
                push("https://www.youtube.com/watch?v=" + vid, title, view or "", "", rel or "")
                continue
            if "videoRenderer" in content:
                vr = content["videoRenderer"]
                vid = vr.get("videoId") or ""
                push("https://www.youtube.com/watch?v=" + vid,
                     text(vr.get("title")),
                     text(vr.get("viewCountText")),
                     text(vr.get("ownerText")),
                     text(vr.get("publishedTimeText")))
                continue
        if "videoRenderer" in item:
            vr = item["videoRenderer"]
            vid = vr.get("videoId") or ""
            push("https://www.youtube.com/watch?v=" + vid,
                 text(vr.get("title")),
                 text(vr.get("viewCountText")),
                 text(vr.get("ownerText")),
                 text(vr.get("publishedTimeText")))

    print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()