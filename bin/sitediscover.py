#!/usr/bin/env python3
"""RSS/Atom-feed van een website opsporen zonder API.

Geeft het domein (of een pagina-URL) mee: haalt de feedlinks uit de pagina,
vult aan met gangbare feedpaden, en zet bij elke gevonden feed een paar eerste
koppen als voorproefje. Geen sitemagie per krant: alle heuristieken zijn
algemeen, zodat het op zoveel mogelijk sites werkt. Compacte JSON.
"""
import html as htmlmod
import json
import re
import subprocess
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# Gangbare feedpaden, grofweg van meest naar minst voorkomend. Per site stoppen
# we zodra er genoeg gevonden is, dus de lijst blijft lang maar het aantal
# verzoeken beperkt.
PROBE = (
    "/rss", "/rss.xml", "/feed", "/feed/", "/rss/news", "/feeds/posts/default",
    "/feeds/posts/default?alt=rss", "/atom.xml", "/feeds/nieuws.xml",
    "/index.xml", "/feed/rss", "/feed/rss.xml", "/latest.rss",
    "/distribution/rss.xml", "/feeds", "/rss/nieuws",
)

# Sectie-slugs om naast de hoofdfeed door te meten. Bewust klein en algemeen:
# niet elke site heeft alle onderdelen, en we willen niet als robot overkomen.
SECTIONS = (
    "buitenland", "binnenland", "politiek", "economie",
    "sport", "tech", "cultuur", "opinie",
)


def get(url, timeout=10):
    # Niet elke site lust een python-socket: DPG, NOS en Tweakers geven urllib
    # een 403. Dit project gebruikt sowieso overal curl; doe hier hetzelfde.
    p = subprocess.run(
        [
            "curl", "-sSL", "--compressed", "--max-time", str(timeout),
            "--proto", "=http,https", "--proto-redir", "=http,https",
            "-A", UA, "-b", "CONSENT=YES+", "-H", "Accept-Language: nl-NL,nl;q=0.9",
            url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if p.returncode != 0 or not p.stdout:
        return None
    return p.stdout


def get_many(urls, timeout=6):
    # Sectie-paden parallel opvragen: tien draadjes, doorliggende curl-processen,
    # zo veel draait een losse zoekopdracht op in één golf.
    with ThreadPoolExecutor(max_workers=10) as ex:
        return list(zip(urls, ex.map(lambda u: get(u, timeout=timeout), urls)))


def looks_like_feed(body):
    if not body:
        return False
    head = body[:8192].decode("utf-8", "replace").lstrip()
    if not head:
        return False
    # Een echte feed is een XML-document dat met <?xml begint, of hooguit
    # direct met <rss>/<feed>/<rdf:RDF>. Een HTML-pagina (privacy-gate,
    # Cloudflare-uitdaging, indexpagina) doet dat nooit.
    if head.startswith("<?xml"):
        return bool(re.search(r"<(rss|feed|rdf:RDF)\b", head, re.I))
    return bool(re.match(r"<(rss|feed|rdf:RDF)\b", head, re.I))


def title_of(body):
    if not body:
        return ""
    m = re.search(rb"<title[^>]*>(.*?)</title>", body, re.S)
    if not m:
        return None
    t = m.group(1)
    t = re.sub(rb"<!\[CDATA\[(.*?)\]\]>", rb"\1", t, flags=re.S)
    t = re.sub(rb"\s+", b" ", t).strip().decode("utf-8", "replace")
    return t or None


def feed_samples(body):
    if not body:
        return []
    out = []
    # Boilerplate die sommige sites in hun items herhalen: de kanalen-titel
    # of -beschrijving (DPG plaatst de sitebeschrijving als tweede <title>).
    def norm(b):
        return re.sub(rb"\s+", b" ", re.sub(rb"<!\[CDATA\[(.*?)\]\]>", rb"\1", b, flags=re.S)).lower()
    ch = re.search(rb"<channel>(.*?)</channel>", body, re.S)
    chb = ch.group(1) if ch else b""
    # Items staan (rss2) óók in <channel>; houd de boilerplate tot het eerste
    # <item> zodat artikeltitels nooit als 'herhaalde tekst' wegvallen.
    chb = chb.split(b"<item", 1)[0]
    boiler = set()
    for m in re.finditer(rb"<(?:title|description)[^>]*>(.*?)</(?:title|description)>", chb, re.S):
        t = norm(m.group(1))
        if t:
            boiler.add(t)
    # Het eerste <title> is de feed/kanaaltitel, géén nieuwsbericht.
    for t in re.findall(rb"<title[^>]*>(.*?)</title>", body, re.S)[1:]:
        t = re.sub(rb"<!\[CDATA\[(.*?)\]\]>", rb"\1", t, flags=re.S)
        if norm(t) in boiler:
            continue
        t = re.sub(rb"<[^>]*>", b" ", t)
        t = re.sub(rb"\s+", b" ", t).strip().decode("utf-8", "replace")
        if t:
            out.append(t)
        if len(out) >= 3:
            break
    return out


def clean_title(t):
    if not t:
        return ""
    return re.sub(r"\s*[-|]\s*(?:RSS|Feed|Atom|.*\.\s?\w{2,})$", "", t).strip()


def link_hrefs(html, base):
    out = []
    # <link rel="alternate" type="application/rss+xml" href="...">
    for tag in re.finditer(r"<link\b([^>]*)>", html, re.I):
        attrs = dict(re.findall(r'([\w-]+)\s*=\s*["\']([^"\']*)["\']', tag.group(1)))
        t = attrs.get("type", "").lower()
        rel = attrs.get("rel", "").lower()
        title = attrs.get("title", "").lower()
        href = attrs.get("href")
        if not href:
            continue
        if "rss+xml" in t or "atom+xml" in t or "rss" in t or "atom" in t:
            out.append(urllib.parse.urljoin(base, href))
        elif rel == "alternate" and any(w in title for w in ("rss", "feed", "atom")):
            out.append(urllib.parse.urljoin(base, href))
    # Soms is de feed gewoon een anker: <a href="/rss">RSS</a>.
    for tag in re.finditer(r"<a\b([^>]*)>\s*(.*?)\s*</a>", html, re.I | re.S):
        attrs = dict(re.findall(r'([\w-]+)\s*=\s*["\']([^"\']*)["\']', tag.group(1)))
        href = attrs.get("href")
        body = re.sub(r"<[^>]*>", "", tag.group(2)).lower()
        if not href:
            continue
        if re.match(r"^\s*(rss|feed|atom|feeds?)\s*$", body):
            out.append(urllib.parse.urljoin(base, href))
    return out


def norm(url):
    return urllib.parse.urlunsplit(
        urllib.parse.urlsplit(url)._replace(query="", fragment="")
    ).rstrip("/")


def channel_title(body):
    ch = re.search(rb"<channel>(.*?)</channel>", body, re.S)
    chb = ch.group(1) if ch else body
    m = re.search(rb"<title[^>]*>(.*?)</title>", chb, re.S)
    if not m:
        return ""
    t = re.sub(rb"<!\[CDATA\[(.*?)\]\]>", rb"\1", m.group(1), flags=re.S)
    t = re.sub(rb"\s+", b" ", t).strip().decode("utf-8", "replace")
    return t


def section_label(title):
    # Nette naam uit de eigen feed-titel: "AD:buitenland", "NU - Buitenland",
    # "NOS Buitenland" en "TR: economie" worden allemaal gewoon "Buitenland".
    t = htmlmod.unescape(title or "")
    t = re.sub(r"^(?:AD|TR|VK|PP|NU|NOS|FD)\b\s*(?:[:|\-–—]\s*)?", "", t, flags=re.I).strip()
    t = re.sub(r"\s*[-|–—]\s*[\w .&+-]+\.(?:nl|com|be|net|org)\s*$", "", t, flags=re.I).strip()
    if not t:
        t = title
    return t[:40].rstrip(" -|–—").title() or "sectie"


SECTION_PREFIXES = (
    "nieuws", "categorie", "category", "categories", "sectie",
    "secties", "rubrieken", "topics", "topic", "tag",
)


def html_section_links(html, base):
    """Sectiepaden uit de homepage, bv. /nieuws/astronomie-ruimtevaart/."""
    if not html:
        return []
    if isinstance(html, bytes):
        html = html.decode("utf-8", "replace")
    host = urllib.parse.urlsplit(base).netloc
    out, seen = [], set()
    for href in re.findall(r"""href=["']([^"']+)["']""", html, re.I):
        p = urllib.parse.urlsplit(urllib.parse.urljoin(base, href))
        parts = [x for x in p.path.split("/") if x]
        if p.netloc != host or len(parts) != 2 or parts[0].lower() not in SECTION_PREFIXES:
            continue
        sec = "%s://%s/%s/%s/" % (p.scheme or "https", p.netloc, parts[0], parts[1])
        if sec in seen:
            continue
        seen.add(sec)
        out.append(sec)
        if len(out) >= 10:
            break
    return out


def discover_sections(root_url, root_body, home, home_html=""):
    """Sectie-feeds naast een hoofdfeed zoeken, zonder sitespecifieke logica.

    De url-opbouw volgt de 'familie' die de hoofdfeed verraadt: DPG-sites
    (AD/Trouw/VK) serveren secties op "<home>/<sectie>/rss.xml", NU op
    "<home>/rss/<sectie>", NOS is verhuisd naar feeds.nos.nl/nosnieuws<sectie>.
    Van onbekende sites proberen we beide generieke patronen. Alleen echte
    feeds tellen: privacygates en Cloudflare vallen af op looks_like_feed.
    """
    title = channel_title(root_body)
    root_host = urllib.parse.urlsplit(root_url).netloc
    family = None
    if "feeds.nos.nl" in root_host or re.match(r"NOS\b", title):
        family = "nos"
    elif re.match(r"(?:AD|TR|VK|PP)\b", title) or "/home/rss" in root_url:
        family = "dpg"
    elif re.match(r"NU\b", title):
        family = "nu"
    if family == "nos":
        cands = ["https://feeds.nos.nl/nosnieuws" + s for s in SECTIONS]
    elif family == "dpg":
        cands = ["%s/%s/rss.xml" % (home, s) for s in SECTIONS]
    elif family == "nu":
        cands = ["%s/rss/%s" % (home, s) for s in SECTIONS]
    else:
        cands = ["%s/%s/rss.xml" % (home, s) for s in SECTIONS]
        cands += ["%s/rss/%s" % (home, s) for s in SECTIONS]

    # Secties die de homepage zelf linkt (WordPress en o.a. Scientias:
    # /nieuws/astronomie-ruimtevaart/feed/) zijn beter dan geraden paden.
    for sec in html_section_links(home_html, home):
        cands.append(sec + "feed/")
        cands.append(sec + "rss")

    root_samples = tuple(feed_samples(root_body))
    out, seen_key = [], set()
    for url, b in get_many(cands, timeout=5):
        if not looks_like_feed(b):
            continue
        smp = tuple(feed_samples(b))
        if not smp or smp == root_samples or smp in seen_key:
            continue
        seen_key.add(smp)
        name = section_label(channel_title(b))
        out.append({"name": name, "value": url, "shape": smp})
        if len(out) >= 8:
            break
    return out


def main():
    term = sys.argv[1] if len(sys.argv) > 1 else ""
    if not term:
        sys.stdout.write('{"ok":0,"reason":"geef een domein of URL"}')
        return 0

    raw = term.strip()
    if "://" not in raw:
        raw = "https://" + raw
    parsed = urllib.parse.urlparse(raw)
    netloc = parsed.netloc
    if "." not in netloc:
        sys.stdout.write(
            json.dumps({"ok": 0, "reason": "dit ziet er niet uit als een website"}, ensure_ascii=False)
        )
        return 0
    base = "https://" + netloc
    target = raw if parsed.path else raw + "/"

    found = []
    body = get(target)
    if body:
        if looks_like_feed(body):
            found.append(target.replace("http://", "https://"))
        else:
            html = body.decode("utf-8", "replace")
            found.extend(link_hrefs(html, target))

    # Proberen op het hoofddomein, ook als de opgegeven pagina een subpad had.
    for cand in PROBE:
        if len(found) >= 5:
            break
        url = norm(base + cand)
        if any(norm(f) == url for f in found):
            continue
        b = get(url, timeout=6)
        if not looks_like_feed(b):
            continue
        found.append(url)
        # Eén echte feed gevonden wil niet zeggen dat de rest niet bestaat,
        # maar wel dat we de klant al iets kunnen geven.
        if len(found) >= 2:
            break

    seen, seen_key, results = set(), set(), []
    for url in found:
        if norm(url) in seen:
            continue
        seen.add(norm(url))
        b = get(url)
        if not looks_like_feed(b):
            continue
        name = clean_title(title_of(b))
        if not name:
            name = netloc
        smp = feed_samples(b)
        # Een feed zonder berichten is geen bruikbare bron; dezelfde feed
        # onder verschillende paden is een alias, geen tweede bron.
        if not smp:
            continue
        key = tuple(smp)
        if key in seen_key:
            continue
        seen_key.add(key)
        results.append({
            "name": name,
            "value": url,
            "kind": "feed",
            "note": netloc,
            "sample": smp,
        })

    if not results:
        sys.stdout.write(
            json.dumps(
                {"ok": 0, "reason": "geen rss-feed gevonden op %s (probeer bijvoorbeeld %s/rss)" % (netloc, netloc)},
                ensure_ascii=False,
            )
        )
        return 0

    # Secties aanbieden op het hoofddomein; heeft de gebruiker zelf al een pad
    # (tussenkopje) opgegeven, dan is die vondst al de gewenste sectie.
    if parsed.path in ("", "/"):
        root_parsed = urllib.parse.urlsplit(results[0]["value"])
        root_body = get(results[0]["value"])
        home_html = ""
        if isinstance(body, bytes) and not looks_like_feed(body):
            home_html = body.decode("utf-8", "replace")
        if root_body and looks_like_feed(root_body):
            for s in discover_sections(
                results[0]["value"], root_body, "https://" + root_parsed.netloc, home_html
            ):
                key = s["shape"]
                if key in seen_key:
                    continue
                seen_key.add(key)
                results.append({
                    "name": s["name"],
                    "value": s["value"],
                    "kind": "feed",
                    "note": "sectie",
                    "sample": list(key),
                })
                if len(results) >= 10:
                    break

    sys.stdout.write(json.dumps({"ok": 1, "results": results}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    main()