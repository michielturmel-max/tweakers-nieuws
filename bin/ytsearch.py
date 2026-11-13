#!/usr/bin/env python3
# Haalt de kanalen uit een YouTube-zoekpagina (ytInitialData). De pagina wordt
# al door het bash-script binnen gehaald (met consent-cookie), dit script
# draait alleen de parser. Uitvoer: {"ok":1,"results":[{name,handle,subscribers,videos}]}.
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
    return value.get("simpleText") or ""


def main():
    if len(sys.argv) > 1:
        try:
            with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
                html = fh.read()
        except OSError as exc:
            print(json.dumps({"ok": 0, "reason": "kon zoekpagina niet lezen: %s" % exc}))
            return
    else:
        html = sys.stdin.read()

    m = re.search(r"var ytInitialData\s*=\s*(\{.*?\})\s*;\s*</script>", html, re.S)
    if not m:
        print(json.dumps({"ok": 0, "reason": "geen zoekresultaten op de pagina"}))
        return
    try:
        data = json.loads(m.group(1))
    except (ValueError, TypeError) as exc:
        print(json.dumps({"ok": 0, "reason": "onleesbare zoekresultaten: %s" % exc}))
        return

    results = []
    try:
        two = data["contents"]["twoColumnSearchResultsRenderer"]
        sections = two["primaryContents"]["sectionListRenderer"]["contents"]
    except (KeyError, TypeError):
        sections = []

    for section in sections:
        if "itemSectionRenderer" not in section:
            continue
        for item in section["itemSectionRenderer"].get("contents", []):
            channel = item.get("channelRenderer")
            if not channel:
                continue
            name = text(channel.get("title"))
            if not name:
                continue
            nav = (channel.get("navigationEndpoint") or {}).get("browseEndpoint") or {}
            handle = (nav.get("canonicalBaseUrl") or "").rstrip("/") or ""
            if not handle:
                cid = channel.get("channelId")
                handle = "@" + cid if cid else ""

            # In de kanalenzoeking verhuizen de aantallen: de ene opmaak
            # zet abonnees onder videoCountText, de andere onder
            # subscriberCountText. Kiezen op inhoud, niet op veldnaam.
            candidates = [
                text(channel.get("videoCountText")),
                text(channel.get("subscriberCountText")),
                text(channel.get("longBylineText")),
            ]
            subs = ""
            videos = ""
            for c in candidates:
                if "abonnee" in c and not subs:
                    subs = c
                elif ("video" in c and not videos and "abonnee" not in c):
                    videos = c
            if not subs:
                subs = candidates[0] if candidates and "/" not in candidates[0] else ""

            results.append({
                "name": name,
                "handle": handle.lstrip("/"),
                "subscribers": subs,
                "videos": videos,
            })
            if len(results) >= 8:
                break
        if len(results) >= 8:
            break

    payload = {"ok": 1 if results else 0, "results": results}
    if not results:
        payload["reason"] = "geen kanalen gevonden"
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()