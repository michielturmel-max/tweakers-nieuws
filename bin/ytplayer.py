#!/usr/bin/env python3
# Videobeschrijving uit de kijkpagina van YouTube halen (ytInitialPlayerResponse)
# zodat een artikelblok in het paneel werkt zonder de oude, nu 404-ende
# feeds/videos.xml-route. Uitvoer in dezelfde vorm als de andere
# artikel-extractors: {"ok":1,"title","author","date","blocks":[...]}.
import json
import re
import sys


def stext(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return value.get("simpleText") or value.get("content") or ""
    return ""


def main():
    if len(sys.argv) > 1:
        try:
            with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
                html = fh.read()
        except OSError as exc:
            print(json.dumps({"ok": 0, "reason": "kon video-pagina niet lezen: %s" % exc}, ensure_ascii=False, separators=(",", ":")))
            return
    else:
        html = sys.stdin.read()

    m = re.search(r"var ytInitialPlayerResponse\s*=\s*(\{.*?\})\s*;\s*(?:var |</script>)", html, re.S)
    if not m:
        print(json.dumps({"ok": 0, "reason": "geen videogegevens op de pagina"}, separators=(",", ":")))
        return
    try:
        data = json.loads(m.group(1))
    except (ValueError, TypeError) as exc:
        print(json.dumps({"ok": 0, "reason": "onleesbare videogegevens: %s" % exc}, separators=(",", ":")))
        return

    vd = data.get("videoDetails") or {}
    micro = ((data.get("microformat") or {}).get("playerMicroformatRenderer")) or {}
    desc = (vd.get("shortDescription") or "").strip()
    if not desc:
        print(json.dumps({"ok": 0, "reason": "lege beschrijving"}, separators=(",", ":")))
        return

    title = stext(micro.get("title")) or stext(vd.get("title")) or ""
    author = (micro.get("ownerChannelName") or vd.get("author") or "")
    date = (micro.get("publishDate") or "")[:10]

    blocks = []
    for para in re.split(r"\n\s*\n|\n", desc):
        t = re.sub(r"<[^>]*>", "", para)
        t = re.sub(r"\s+", " ", t).strip()
        if not t:
            continue
        blocks.append({"t": "p", "x": t, "r": [{"x": t}]})
        if len(blocks) >= 200:
            break

    print(json.dumps({
        "ok": 1 if blocks else 0,
        "title": title, "author": author, "date": date, "reacties": "",
        "blocks": blocks,
    }, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()