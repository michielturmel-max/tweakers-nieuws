#!/usr/bin/env python3
"""Generieke artikeltekstextractie voor de nieuws-widget.

De Tweakers-specifieke extractor in tweakers-nieuws verstaat één CMS; voor
alle andere sites haalt dit script de tekst uit een willekeurige nieuwspagina.
Het principe is de klassieke "text density": zoek het kleinste blok dat de
meeste paragraaftekst bevat, en geef al zijn paragrafen in volgorde terug.

Werkt overal: gebruikt bs4 alleen als het toevallig geïnstalleerd is, anders
een eigen minimale DOM op de standaardbibliotheek. Uitvoer is dezelfde
json-vorm als de perl-extractor:
{"ok","title","author","date","reacties","blocks"}, waarin elk blok
{"t":"p|h|li|quote","x":"tekst","r":[{"x",..,"h"?},..]} is.
"""
import json
import re
import sys

try:
    from bs4 import BeautifulSoup
    HAS_BS4 = True
except ImportError:
    HAS_BS4 = False

NOISE = {"script", "style", "nav", "footer", "header", "aside", "form",
         "noscript", "iframe", "svg", "button", "template", "select", "menu",
         "dialog", "slot", "picture", "source"}

# Klassen die op teasers, advertenties en consent-muren wijzen. Zulke blokken
# staan vaak midden in de artikelcontainer; zonder deze filter belanden
# "lees ook"-kaartjes en cookiebalken in de leesweergave.
NOISE_CLASSES = ("relatedteaser", "related-teaser", "related-article",
                 "related_article", "lees-ook", "read-more", "readmore",
                 "advert", "ad-label", "ad-element", "advertisement",
                 "promo", "newsletter", "cookie", "consent", "didomi",
                 "paywall", "subscribe", "outbrain", "taboola", "breadcrumb",
                 "social-share", "share-button", "tag-list", "comment")


def clean(t):
    return re.sub(r"\s+", " ", t).replace("\u00a0", " ").strip()


class TextNode:
    name = None

    def __init__(self, data):
        self.data = data

    def get(self, key, default=""):
        return default


class Node:
    __slots__ = ("tag", "name", "attrs", "children", "parent")

    def __init__(self, tag, attrs=None):
        self.tag = tag
        self.name = tag
        self.attrs = attrs or {}
        self.children = []
        self.parent = None

    def get(self, key, default=""):
        return self.attrs.get(key, default)

    def append(self, child):
        child.parent = self
        self.children.append(child)

    def get_text(self, sep="", strip=False):
        parts = []

        def rec(n):
            if n.name is None:
                parts.append(n.data)
            else:
                for c in n.children:
                    rec(c)

        rec(self)
        if strip:
            parts = [p.strip() for p in parts]
        return sep.join(parts)

    def decompose(self):
        if self.parent is not None:
            try:
                self.parent.children.remove(self)
            except ValueError:
                pass
        self.parent = None

    @property
    def body(self):
        return self.find("body") or self

    def find_all(self, tags):
        if isinstance(tags, str):
            tags = (tags,)
        wanted = set(tags)
        out = []

        def rec(n):
            for c in n.children:
                if c.name is not None:
                    if c.name in wanted:
                        out.append(c)
                    rec(c)

        rec(self)
        return out

    def find(self, tag):
        want = set((tag,)) if isinstance(tag, str) else tag

        def rec(n):
            for c in n.children:
                if c.name is not None:
                    if c.name in want:
                        return c
                    hit = rec(c)
                    if hit is not None:
                        return hit
            return None

        return rec(self)

    def select_one(self, css):
        m = re.fullmatch(r"(?:(?P<tag>[A-Za-z][\w-]*))?"
                         r"(?:\[(?P<attr>[\w-]+)(?:=(?P<val>['\"])(?P<val2>.*?)(?P=val))?\])?",
                         css)
        if not m:
            return None
        tag = m.group("tag")
        attr = m.group("attr")
        want = m.group("val2")

        def rec(n):
            for c in n.children:
                if c.name is not None:
                    if tag and c.name != tag:
                        pass
                    elif attr:
                        got = c.get(attr)
                        if got is None:
                            pass
                        elif want is not None and str(got) != want:
                            pass
                        else:
                            return c
                    else:
                        return c
                    hit = rec(c)
                    if hit is not None:
                        return hit
            return None

        return rec(self)


class _Parser:
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self):
        import html.parser
        self._hp = html.parser.HTMLParser(convert_charrefs=True)
        self.root = Node("html")
        self.stack = [self.root]

    def feed(self, data):
        if isinstance(data, bytes):
            data = data.decode("utf-8", "replace")
        hp = self._hp
        hp.handle_starttag = self._start
        hp.handle_startendtag = self._startend
        hp.handle_endtag = self._end
        hp.handle_data = self._data
        hp.feed(data)

    def _start(self, tag, attrs):
        node = Node(tag, dict(attrs) if attrs else {})
        self.stack[-1].append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def _startend(self, tag, attrs):
        node = Node(tag, dict(attrs) if attrs else {})
        self.stack[-1].append(node)

    def _end(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def _data(self, data):
        self.stack[-1].children.append(TextNode(data))


def _class_text(el):
    attrs = getattr(el, "attrs", None)
    if not attrs:
        return ""
    cls = attrs.get("class") or ""
    if isinstance(cls, (list, tuple)):
        cls = " ".join(cls)
    return str(cls).lower()


def strip_noise_classes(root):
    for el in root.find_all(["div", "section", "aside", "a", "ul", "ol", "span", "p"]):
        if el.name in ("html", "body", "article", "main"):
            continue
        if getattr(el, "parent", None) is None:
            continue
        cls = _class_text(el)
        if cls and any(n in cls for n in NOISE_CLASSES):
            el.decompose()


def parse_page(data):
    if HAS_BS4:
        soup = BeautifulSoup(data, "html.parser")
    else:
        parser = _Parser()
        parser.feed(data)
        soup = parser.root
    for el in soup.find_all(list(NOISE)):
        el.decompose()
    strip_noise_classes(soup)
    return soup


def para_score(el):
    return sum(len(p.get_text(" ", strip=True)) for p in el.find_all("p"))


def _class_has(el, needle):
    cls = el.get("class") or ""
    if isinstance(cls, (list, tuple)):
        cls = " ".join(cls)
    return needle.lower() in str(cls).lower()


def pick_root(root):
    for sel in ("[itemprop='articleBody']", "[data-element='articleBody']", "[data-testid='article-body']"):
        hit = root.select_one(sel)
        if hit is not None and para_score(hit) >= 60:
            return hit

    needles = ("article-body", "articlebody", "article__body", "article-content",
               "articlecontent", "story-body", "post-content", "artdetail",
               "detail__body", "tekst", "bodycopy")
    for el in root.find_all(["div", "section", "article", "main"]):
        if any(_class_has(el, n) for n in needles) and para_score(el) >= 60:
            return el

    for tag in ("article", "main"):
        hit = root.find(tag)
        if hit is not None and para_score(hit) >= 60:
            return hit

    best = None
    best_score = 0
    for el in root.find_all(["div", "section"]):
        score = para_score(el)
        if score >= 80:
            txtlen = len(el.get_text(" ", strip=True))
            if best is None or score > best_score * 1.1 or (
                    best_score > 0 and score >= best_score * 0.9
                    and txtlen < len(best.get_text(" ", strip=True))):
                best, best_score = el, score
    if best is not None:
        return best
    return getattr(root, "body", None) or root


BLOCK_TAGS = {"p", "li", "blockquote", "h1", "h2", "h3", "h4", "h5"}


def flush(buf, runs):
    if buf:
        s = clean("".join(buf))
        if s:
            runs.append({"x": s})
        buf.clear()


def collect(node, buf, runs):
    if node.name is None:
        buf.append(re.sub(r"\s+", " ", getattr(node, "data", str(node))))
        return
    if node.name in NOISE:
        return
    if node.name == "a":
        href = node.get("href")
        t = clean(node.get_text(" ", strip=True))
        if href and t and not t.lower().startswith("#"):
            flush(buf, runs)
            runs.append({"x": t, "h": href})
        else:
            _collect_children(node, buf, runs)
        return
    _collect_children(node, buf, runs)


def _collect_children(node, buf, runs):
    for child in node.children:
        collect(child, buf, runs)


def walk_blocks(node):
    for child in node.children:
        if child.name is None or child.name in NOISE:
            continue
        if child.name in BLOCK_TAGS:
            yield child
        else:
            yield from walk_blocks(child)


def build_blocks(root):
    blocks = []
    seen = set()
    for el in walk_blocks(root):
        buf, runs = [], []
        collect(el, buf, runs)
        flush(buf, runs)
        text = clean("".join(r.get("x", "") for r in runs))
        if len(text) <= 2:
            continue
        if text in seen:
            continue
        seen.add(text)
        if el.name in ("h1", "h2", "h3", "h4", "h5"):
            kind = "h"
        elif el.name == "li":
            kind = "li"
        elif el.name == "blockquote":
            kind = "quote"
        else:
            kind = "p"
        if kind == "li" and len(runs) == 1 and runs[0].get("h"):
            continue
        blocks.append({"t": kind, "x": text, "r": runs})
    return blocks


def main():
    path, url = sys.argv[1:3]
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as e:
        print(json.dumps({"ok": 0, "reason": f"kon pagina niet lezen: {e}"}))
        return 1

    raw = data.decode("utf-8", "replace") if isinstance(data, bytes) else data

    # Een betaald artikel levert in de browser alleen de paywall op; de
    # volledige tekst komt nooit in de HTML. Dat herkennen we hier, zodat het
    # paneel de intro uit de feed kan tonen in plaats van abonnementsknoppen.
    premium = bool(re.search(
        r'"isPremium"\s*:\s*true|"isAccessibleForFree"\s*:\s*false',
        raw, re.I))

    soup = parse_page(data)

    title = ""
    for sel in ("meta[property='og:title']", "meta[name='twitter:title']",
                "meta[name='title']"):
        el = soup.select_one(sel)
        t = el.get("content") if el is not None else ""
        if t and len(t) >= 6:
            title = clean(t)
            break
    if not title:
        h = soup.select_one("title")
        title = clean(h.get_text(" ", strip=True)) if h is not None else ""
    if not title:
        h = soup.select_one("h1")
        title = clean(h.get_text(" ", strip=True)) if h is not None else ""

    author = ""
    for sel in ("meta[name='author']", "meta[property='article:author']"):
        el = soup.select_one(sel)
        if el is not None and el.get("content"):
            author = clean(el.get("content"))
            break
    if not author:
        for sel in ("[rel='author']", "[itemprop='author']"):
            el = soup.select_one(sel)
            if el is not None:
                author = clean(el.get_text(" ", strip=True))
                break
    if not author:
        for el in soup.find_all(["a", "span", "div", "p"]):
            cls = _class_text(el)
            if ("author" in cls or "byline" in cls) and "author-bio" not in cls:
                t = clean(el.get_text(" ", strip=True))
                if 2 <= len(t) <= 80:
                    author = t
                    break
    author = re.sub(r"\s*[,|]\s*.*$", "", author)

    date = ""
    for sel in ("meta[property='article:published_time']",
                "time[datetime]", "time", "meta[name='date']"):
        el = soup.select_one(sel)
        if el is not None:
            d = el.get("datetime") or el.get("content") or ""
            if d:
                date = clean(d)[:19].replace("T", " ")
                break

    root = pick_root(soup)
    if root is None:
        print(json.dumps({"ok": 0, "reason": "geen artikeltekst"}))
        return 0
    blocks = build_blocks(root)

    if premium and sum(len(b["x"]) for b in blocks) < 800:
        print(json.dumps({"ok": 0, "premium": 1,
                          "reason": "premium artikel, alleen leesbaar met een abonnement"},
                         ensure_ascii=False))
        return 0

    if len(blocks) < 1:
        desc = ""
        for sel in ("meta[property='og:description']", "meta[name='description']",
                    "meta[name='twitter:description']"):
            el = soup.select_one(sel)
            if el is not None and el.get("content"):
                desc = clean(el.get("content"))
                if desc:
                    break
        if desc:
            blocks = [{"t": "p", "x": desc, "r": [{"x": desc}]}]
        else:
            print(json.dumps({"ok": 0, "reason": "geen artikeltekst"}))
            return 0

    payload = {
        "ok": 1,
        "title": title or url,
        "author": author,
        "date": date,
        "reacties": "",
        "blocks": blocks,
    }
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())