#!/usr/bin/env python3
import html
import hashlib
import ipaddress
import json
import os
import re
import sys
import struct
import tempfile
import binascii
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from socket import getaddrinfo

MAX_RESPONSE = 2 * 1024 * 1024
MAX_ITEMS = 100
MAX_TEXT = 12000


def safe_url(value):
    value = str(value or "").strip()
    parsed = urllib.parse.urlsplit(value)
    if (
        len(value) > 2048
        or parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.port not in (None, 443)
    ):
        raise ValueError("Only public HTTPS feed and article URLs are supported.")
    hostname = parsed.hostname.lower().rstrip(".")
    if hostname in {"localhost", "localhost.localdomain"} or hostname.endswith(".local"):
        raise ValueError("Local network addresses are not supported.")
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        raise ValueError("Local network addresses are not supported.")
    return value


def validate_public_host(url):
    hostname = urllib.parse.urlsplit(url).hostname
    try:
        addresses = {entry[4][0] for entry in getaddrinfo(hostname, 443)}
    except OSError as error:
        raise ValueError("The host could not be resolved.") from error
    if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
        raise ValueError("Local network addresses are not supported.")


class PublicHttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        validate_public_host(safe_url(new_url))
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected is not None:
            response.close()
        return redirected


def fetch(url):
    url = safe_url(url)
    validate_public_host(url)
    opener = urllib.request.build_opener(PublicHttpsRedirect)
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "MyRSS/0.1 (RSS reader)", "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, text/html"},
    )
    with opener.open(request, timeout=8) as response:
        final_url = safe_url(response.geturl())
        content_type = response.headers.get("Content-Type", "").lower()
        if not any(kind in content_type for kind in ("xml", "rss", "atom", "html", "text/")):
            raise ValueError("The server did not return an RSS, Atom, or HTML document.")
        data = response.read(MAX_RESPONSE + 1)
        if len(data) > MAX_RESPONSE:
            raise ValueError("The response exceeded the 2 MiB limit.")
        return data, final_url


class PlainText(HTMLParser):
    BLOCKS = {"p", "div", "br", "li", "h1", "h2", "h3", "h4", "blockquote", "article"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "noscript", "svg"}:
            self.skip_depth += 1
        elif tag in self.BLOCKS and self.skip_depth == 0:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"script", "style", "noscript", "svg"} and self.skip_depth:
            self.skip_depth -= 1
        elif tag in self.BLOCKS and self.skip_depth == 0:
            self.parts.append("\n")

    def handle_data(self, data):
        if self.skip_depth == 0:
            self.parts.append(data)


def plain_text(value):
    parser = PlainText()
    try:
        parser.feed(str(value or "")[:MAX_RESPONSE])
    except Exception:
        pass
    result = html.unescape("".join(parser.parts))
    result = re.sub(r"[ \t\r\f\v]+", " ", result)
    result = re.sub(r"\n[ \t]*\n+", "\n\n", result)
    return result.strip()[:MAX_TEXT]


def child_text(element, names):
    for child in element.iter():
        if child.tag.split("}")[-1].lower() in names:
            value = "".join(child.itertext()).strip()
            if value:
                return value
    return ""


def image_candidate(value, source_url):
    url = urllib.parse.urljoin(source_url, value)
    try:
        return safe_url(url)[:2048]
    except ValueError:
        return ""


class FeedImage(HTMLParser):
    def __init__(self, source_url):
        super().__init__(convert_charrefs=True)
        self.source_url = source_url
        self.image = ""

    def handle_starttag(self, tag, attrs):
        if tag != "img" or self.image:
            return
        attrs = dict(attrs)
        value = attrs.get("src") or attrs.get("data-src")
        if value:
            self.image = image_candidate(value, self.source_url)


def article_image(element, source_url):
    for child in element.iter():
        tag = child.tag.split("}")[-1].lower()
        url = child.attrib.get("url") or child.attrib.get("href") or ""
        if tag in {"thumbnail", "content", "enclosure", "image"} and url:
            mime = child.attrib.get("type", "").lower()
            medium = child.attrib.get("medium", "").lower()
            path = urllib.parse.urlsplit(url).path.lower()
            if (mime and not mime.startswith("image/")) or medium in {"video", "audio"}:
                continue
            if path.endswith((".webm", ".mp4", ".mov", ".mp3", ".ogg")):
                continue
            candidate = image_candidate(url, source_url)
            if candidate:
                return candidate
    for child in element.iter():
        if child.tag.split("}")[-1].lower() in {"encoded", "description", "summary", "content"}:
            parser = FeedImage(source_url)
            parser.feed("".join(child.itertext())[:MAX_RESPONSE])
            if parser.image:
                return parser.image
    return ""


def parse_feed(data, source_url):
    root = ET.fromstring(data)
    channel = next((node for node in root.iter() if node.tag.split("}")[-1].lower() == "channel"), root)
    title = plain_text(child_text(channel, {"title"})) or urllib.parse.urlsplit(source_url).hostname
    entries = [node for node in root.iter() if node.tag.split("}")[-1].lower() in {"item", "entry"}]
    items = []
    for index, entry in enumerate(entries[:MAX_ITEMS]):
        link = ""
        for node in entry:
            if node.tag.split("}")[-1].lower() == "link":
                link = node.attrib.get("href") or (node.text or "").strip()
                if link:
                    break
        try:
            link = safe_url(urllib.parse.urljoin(source_url, link))
        except ValueError:
            continue
        description = child_text(entry, {"encoded", "description", "summary", "content"})
        item_title = plain_text(child_text(entry, {"title"})) or "Untitled article"
        date = plain_text(child_text(entry, {"published", "updated", "pubdate", "date"}))[:120]
        items.append({
            "id": link,
            "title": item_title[:500],
            "link": link,
            "date": date,
            "summary": plain_text(description)[:2000],
            "image": article_image(entry, source_url),
            "content": plain_text(description),
        })
    return {"ok": True, "title": title[:200], "url": source_url, "items": items}


class ArticleLimitError(ValueError):
    pass


class ArticleText(HTMLParser):
    EXCLUDED = {"script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form"}
    VOID = {"img", "br", "hr", "meta", "link", "input", "source", "wbr", "area", "embed"}
    MAX_DEPTH = 128
    MAX_NODES = 50000
    MAX_CANDIDATES = 256
    MAX_FRAGMENTS = 16384
    MAX_RETAINED_TEXT = 1024 * 1024

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.candidates = []
        self.fallback = []
        self.nodes = 0
        self.fragments = 0
        self.retained_text = 0

    def limit_exceeded(self):
        raise ArticleLimitError("Article HTML exceeds safe extraction limits. Open the original in your browser.")

    def handle_starttag(self, tag, attrs):
        self.nodes += 1
        if self.nodes > self.MAX_NODES or (tag not in self.VOID and len(self.stack) >= self.MAX_DEPTH):
            self.limit_exceeded()
        attrs = dict(attrs)
        parent_skipped = bool(self.stack and self.stack[-1]["skipped"])
        skipped = parent_skipped or tag in self.EXCLUDED
        marker = attrs.get("class", "") + " " + attrs.get("id", "")
        priority = 3 if tag == "article" else 2 if tag == "main" else 1 if re.search(
            r"(?:entry|post|article)[-_](?:content|body)|story-body", marker, re.I
        ) else 0
        candidate = {"priority": priority, "parts": []} if priority and not skipped else None
        if candidate:
            if len(self.candidates) >= self.MAX_CANDIDATES:
                self.limit_exceeded()
            self.candidates.append(candidate)
        if not skipped and tag in PlainText.BLOCKS:
            self.append("\n")
        if tag not in self.VOID:
            self.stack.append({"tag": tag, "skipped": skipped, "candidate": candidate})

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index]["tag"] == tag:
                if not self.stack[index]["skipped"] and tag in PlainText.BLOCKS:
                    self.append("\n")
                del self.stack[index:]
                break

    def append(self, text):
        if not text:
            return
        destinations = [node["candidate"]["parts"] for node in self.stack if node["candidate"]]
        if any(node["tag"] in {"p", "li", "h1", "h2", "h3", "blockquote", "pre"} for node in self.stack):
            destinations.append(self.fallback)
        # Count duplicated references and characters across all candidate lists.
        fragments = self.fragments + len(destinations)
        retained_text = self.retained_text + len(text) * len(destinations)
        if fragments > self.MAX_FRAGMENTS or retained_text > self.MAX_RETAINED_TEXT:
            self.limit_exceeded()
        self.fragments = fragments
        self.retained_text = retained_text
        for parts in destinations:
            parts.append(text)

    def handle_data(self, text):
        if not self.stack or not self.stack[-1]["skipped"]:
            self.append(text)

    def content(self):
        candidates = [candidate for candidate in self.candidates if "".join(candidate["parts"]).strip()]
        if candidates:
            best = max(candidates, key=lambda candidate: (candidate["priority"], len("".join(candidate["parts"]))))
            text = "".join(best["parts"])
        else:
            text = "".join(self.fallback)
        text = re.sub(r"[ \t\r\f\v]+", " ", text)
        return re.sub(r"\n[ \t]*\n+", "\n\n", text).strip()[:MAX_TEXT]


def article(url):
    data, final_url = fetch(url)
    text = data.decode("utf-8", errors="replace")
    title_match = re.search(r"<title[^>]*>(.*?)</title\s*>", text, re.I | re.S)
    parser = ArticleText()
    parser.feed(text[:MAX_RESPONSE])
    body = parser.content()
    if not body:
        raise ValueError("No readable article text was found. Open the original in your browser.")
    return {
        "ok": True,
        "url": final_url,
        "requestedUrl": url,
        "title": plain_text(title_match.group(1))[:500] if title_match else "",
        "content": body,
    }


def sanitize_png(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Invalid PNG thumbnail.")
    output = bytearray(data[:8])
    position = 8
    seen = set()
    idat_finished = False
    color = depth = 0
    palette_entries = 0
    for _ in range(1024):
        if position + 12 > len(data):
            break
        length = int.from_bytes(data[position:position + 4], "big")
        end = position + 12 + length
        if end > len(data):
            break
        kind = data[position + 4:position + 8]
        payload = data[position + 8:end - 4]
        if (not re.fullmatch(b"[A-Za-z]{4}", kind) or kind[2] & 32
                or binascii.crc32(kind + payload) != int.from_bytes(data[end - 4:end], "big")):
            break
        if not seen and kind != b"IHDR":
            break
        if b"IDAT" in seen and kind != b"IDAT":
            idat_finished = True
        if kind == b"IHDR":
            if seen or length != 13:
                break
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
            if (not 0 < width <= 4096 or not 0 < height <= 4096 or width * height > 4_000_000
                    or depth not in depths.get(color, ()) or compression or filtering or interlace not in (0, 1)):
                break
        elif kind == b"PLTE":
            if (kind in seen or b"IDAT" in seen or b"tRNS" in seen or color in (0, 4)
                    or not 0 < length <= 768 or length % 3
                    or (color == 3 and length // 3 > 2 ** depth)):
                break
        elif kind == b"tRNS":
            if kind in seen or b"IDAT" in seen:
                break
            if not ((color == 0 and length == 2) or (color == 2 and length == 6)
                    or (color == 3 and b"PLTE" in seen and 0 < length <= palette_entries)):
                break
        elif kind == b"IDAT":
            if idat_finished or (color == 3 and b"PLTE" not in seen):
                break
        elif kind == b"IEND":
            if length or b"IDAT" not in seen or end != len(data):
                break
            output.extend(data[position:end])
            return bytes(output)
        elif not kind[0] & 32:
            break
        # Drop all other ancillary chunks without inflating text or profiles.
        if kind in (b"IHDR", b"PLTE", b"tRNS", b"IDAT"):
            output.extend(data[position:end])
        if kind == b"PLTE":
            palette_entries = length // 3
        seen.add(kind)
        position = end
    raise ValueError("Invalid or oversized PNG thumbnail.")


def sanitize_thumbnail(data, mime):
    if len(data) > 512 * 1024:
        raise ValueError("The thumbnail exceeded the 512 KiB limit.")
    if mime == "image/png":
        return sanitize_png(data), ".png"
    if mime == "image/jpeg" and data.startswith(b"\xff\xd8\xff"):
        return data, ".jpg"
    if (mime == "image/webp" and len(data) >= 12 and data[:4] == b"RIFF"
            and data[8:12] == b"WEBP" and int.from_bytes(data[4:8], "little") == len(data) - 8):
        return data, ".webp"
    raise ValueError("The thumbnail format does not match its content type.")


def image(url):
    url = safe_url(url)
    validate_public_host(url)
    opener = urllib.request.build_opener(PublicHttpsRedirect)
    request = urllib.request.Request(url, headers={"User-Agent": "MyRSS/0.1"})
    with opener.open(request, timeout=6) as response:
        final_url = safe_url(response.geturl())
        validate_public_host(final_url)
        mime = response.headers.get("Content-Type", "").split(";", 1)[0].lower()
        extensions = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
        if mime not in extensions:
            raise ValueError("Only JPEG, PNG, and WebP thumbnails are supported.")
        data = response.read(512 * 1024 + 1)
        data, extension = sanitize_thumbnail(data, mime)
    cache_root = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))
    cache_dir = os.path.join(cache_root, "omarchy", "news-reader", "images-v2")
    os.makedirs(cache_dir, mode=0o700, exist_ok=True)
    digest = hashlib.sha256(data).hexdigest()
    name = digest + extension
    path = os.path.join(cache_dir, name)
    temporary = ""
    try:
        with tempfile.NamedTemporaryFile(dir=cache_dir, prefix=".thumbnail-", delete=False) as output:
            temporary = output.name
            output.write(data)
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    return {"ok": True, "path": path}


def parse_opml(data):
    root = ET.fromstring(data)
    if root.tag != "opml":
        raise ValueError("This is not an OPML subscription file.")
    feeds = []
    seen = set()

    def visit(node, folders, depth=0):
        if depth > 20:
            raise ValueError("The OPML folder nesting is too deep.")
        for child in node:
            if child.tag != "outline":
                continue
            title = (child.get("text") or child.get("title") or "").strip()[:200]
            url = child.get("xmlUrl") or child.get("xmlurl")
            if url:
                url = safe_url(re.sub(r"^http://", "https://", url.strip(), flags=re.I))
                if url not in seen:
                    seen.add(url)
                    feeds.append({"url": url, "title": title or urllib.parse.urlsplit(url).hostname,
                                  "folder": " / ".join(folders)[:100]})
                    if len(feeds) > 100:
                        raise ValueError("An OPML import can contain at most 100 feeds.")
            else:
                visit(child, folders + ([title] if title else []), depth + 1)

    body = root.find("body")
    if body is None:
        raise ValueError("The OPML file has no subscription list.")
    visit(body, [])
    if not feeds:
        raise ValueError("No RSS or Atom subscriptions were found in the OPML file.")
    return feeds


def import_opml(path):
    with open(os.path.expanduser(path), "rb") as source:
        data = source.read(MAX_RESPONSE + 1)
    if len(data) > MAX_RESPONSE:
        raise ValueError("The OPML file exceeded the 2 MiB limit.")
    return {"ok": True, "feeds": parse_opml(data)}


def export_opml(state_path, destination):
    if state_path == "-":
        state = json.loads(sys.stdin.readline(MAX_RESPONSE))
    else:
        with open(state_path, encoding="utf-8") as source:
            state = json.load(source)
    root = ET.Element("opml", version="2.0")
    head = ET.SubElement(root, "head")
    ET.SubElement(head, "title").text = "MyRSS subscriptions"
    body = ET.SubElement(root, "body")
    folders = {}
    for subscription in state.get("feeds", [])[:100]:
        folder = subscription.get("folder", "")
        parent = body
        if folder:
            if folder not in folders:
                folders[folder] = ET.SubElement(body, "outline", text=folder)
            parent = folders[folder]
        ET.SubElement(parent, "outline", type="rss", text=subscription["title"],
                      title=subscription["title"], xmlUrl=safe_url(subscription["url"]))
    data = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    with open(os.path.expanduser(destination), "xb") as output:
        output.write(data)
    return {"ok": True, "path": os.path.expanduser(destination)}


def main(argv):
    if len(argv) == 2 and argv[1] in {"feed", "article", "image"}:
        # URLs can contain bearer tokens; never accept them through argv.
        try:
            request = json.loads(sys.stdin.readline(16385))
            url = request.get("url") if isinstance(request, dict) else None
            if not isinstance(url, str) or len(url) > 2048:
                raise ValueError("Invalid request")
            url = safe_url(url)
            if argv[1] == "feed":
                data, final_url = fetch(url)
                result = parse_feed(data, final_url)
            elif argv[1] == "article":
                result = article(url)
            else:
                result = image(url)
        except ArticleLimitError:
            print(json.dumps({"ok": False, "error":
                "Article HTML exceeds safe extraction limits. Open the original in your browser."}))
            return 1
        except (ValueError, OSError, urllib.error.URLError, TimeoutError, ET.ParseError):
            # Library/server exception messages can echo credentials or URLs.
            print(json.dumps({"ok": False, "error":
                "The HTTPS request failed. Check the URL, access permissions, and connection."}))
            return 1
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if len(argv) == 4 and argv[1] == "export-opml":
        print(json.dumps(export_opml(argv[2], argv[3])))
        return
    if len(argv) != 3 or argv[1] != "import-opml":
        raise ValueError("Usage: feed.py feed|article|image (JSON on stdin), import-opml PATH, or export-opml STATE PATH")
    result = import_opml(argv[2])
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (ValueError, OSError, urllib.error.URLError, TimeoutError, ET.ParseError) as error:
        print(json.dumps({"ok": False, "error": str(error)[:500]}, ensure_ascii=False))
        sys.exit(1)
