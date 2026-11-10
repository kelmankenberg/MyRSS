import importlib.util
import unittest
import json
import tempfile
import io
import http.client
import urllib.request
import subprocess
import struct
import zlib
from contextlib import redirect_stdout
from unittest.mock import Mock, patch
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "feed.py"
SPEC = importlib.util.spec_from_file_location("feed", MODULE_PATH)
feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed)


def png_chunk(kind, payload=b""):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def png_image(*metadata, width=1, height=1):
    return (b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + b"".join(metadata)
            + png_chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\xff"))
            + png_chunk(b"IEND"))


class TrackingBytesIO(io.BytesIO):
    def __init__(self, value):
        super().__init__(value)
        self.tracking = False
        self.body_bytes_read = 0

    def read(self, size=-1):
        value = super().read(size)
        if self.tracking:
            self.body_bytes_read += len(value)
        return value

    def readline(self, size=-1):
        value = super().readline(size)
        if self.tracking:
            self.body_bytes_read += len(value)
        return value


class TrackingSocket:
    def __init__(self, response_bytes):
        self.stream = TrackingBytesIO(response_bytes)

    def makefile(self, mode):
        return self.stream


class FeedTests(unittest.TestCase):
    def test_png_metadata_is_removed_without_decompression(self):
        compressed = zlib.compress(b"x" * 7000)
        metadata = [png_chunk(b"zTXt", b"key\x00\x00" + compressed)] * 70
        metadata += [
            png_chunk(b"iCCP", b"profile\x00\x00" + compressed),
            png_chunk(b"iTXt", b"key\x00\x01\x00\x00\x00" + compressed),
            png_chunk(b"tEXt", b"key\x00text"),
        ]
        original = png_image(*metadata)
        with patch.object(zlib, "decompress", side_effect=AssertionError("Metadata must not be decompressed")):
            sanitized, extension = feed.sanitize_thumbnail(original, "image/png")
        self.assertEqual(extension, ".png")
        self.assertEqual(sanitized, png_image())
        self.assertEqual(feed.sanitize_png(sanitized), sanitized)
        after_pixels = png_image()[:-12] + b"".join(metadata) + png_chunk(b"IEND")
        self.assertEqual(feed.sanitize_png(after_pixels), sanitized)

    def test_png_palette_and_transparency_are_preserved(self):
        image = (b"\x89PNG\r\n\x1a\n"
                 + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 1, 3, 0, 0, 0))
                 + png_chunk(b"PLTE", b"\xff\x00\x00")
                 + png_chunk(b"tRNS", b"\x80")
                 + png_chunk(b"IDAT", zlib.compress(b"\x00\x00"))
                 + png_chunk(b"IEND"))
        self.assertEqual(feed.sanitize_png(image), image)

    def test_png_malformed_structure_and_dimensions_are_rejected(self):
        normal = png_image()
        header = normal[8:33]
        idat = png_chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\xff"))
        invalid = [
            normal[:-1], normal + b"trailing",
            normal[:20] + bytes([normal[20] ^ 1]) + normal[21:],
            png_image(width=0), png_image(width=4097),
            png_image(width=4096, height=4096),
            png_image(png_chunk(b"ABCD")),
            png_image(png_chunk(b"IHDR", b"\x00" * 13)),
            b"\x89PNG\r\n\x1a\n" + header + png_chunk(b"IEND"),
            b"\x89PNG\r\n\x1a\n" + header + idat + png_chunk(b"tEXt", b"k\x00v") + idat + png_chunk(b"IEND"),
            png_image(*[png_chunk(b"tEXt", b"k\x00v")] * 1024),
            png_image(png_chunk(b"tRNS", b"\x00")),
        ]
        for data in invalid:
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                feed.sanitize_png(data)

    def test_mislabeled_png_cannot_bypass_sanitization(self):
        for mime in ("image/jpeg", "image/webp"):
            with self.subTest(mime=mime), self.assertRaises(ValueError):
                feed.sanitize_thumbnail(png_image(), mime)
        with self.assertRaises(ValueError):
            feed.sanitize_thumbnail(b"\xff\xd8\xff" + b"x" * (512 * 1024), "image/jpeg")

    def test_image_cache_never_returns_legacy_or_unsanitized_bytes(self):
        url = "https://example.com/image.png"
        original = png_image(png_chunk(b"zTXt", b"key\x00\x00" + zlib.compress(b"x" * 7000)))
        with tempfile.TemporaryDirectory() as directory:
            legacy = Path(directory) / "omarchy/news-reader/images"
            legacy.mkdir(parents=True)
            (legacy / (feed.hashlib.sha256(url.encode()).hexdigest() + ".png")).write_bytes(original)
            sanitized_path = Path(directory) / "omarchy/news-reader/images-v2" / (
                feed.hashlib.sha256(png_image()).hexdigest() + ".png"
            )
            sanitized_path.parent.mkdir()
            sanitized_path.write_bytes(original)
            response = io.BytesIO(original)
            response.headers = {"Content-Type": "image/png"}
            response.geturl = lambda: url
            opener = Mock()
            opener.open.return_value = response
            with patch.dict(feed.os.environ, {"XDG_CACHE_HOME": directory}), \
                    patch.object(feed, "validate_public_host"), \
                    patch.object(feed.urllib.request, "build_opener", return_value=opener):
                result = feed.image(url)
            self.assertTrue(result["ok"])
            self.assertEqual(Path(result["path"]), sanitized_path)
            self.assertEqual(sanitized_path.read_bytes(), png_image())
            self.assertEqual(list(sanitized_path.parent.glob(".thumbnail-*")), [])

    def test_https_redirects_close_unread_bodies_for_all_redirect_statuses(self):
        body = b"x" * (feed.MAX_RESPONSE + 1)
        frames = (
            ("Content-Length", str(len(body)), body),
            ("Transfer-Encoding", "chunked",
             f"{len(body):X}\r\n".encode() + body + b"\r\n0\r\n\r\n"),
            ("Connection", "close", body),
        )
        for code in (301, 302, 303, 307, 308):
            for header, value, framed_body in frames:
                with self.subTest(code=code, framing=header):
                    response_bytes = (
                        f"HTTP/1.1 {code} Redirect\r\n"
                        f"Location: /next\r\n{header}: {value}\r\n\r\n"
                    ).encode() + framed_body
                    sock = TrackingSocket(response_bytes)
                    response = http.client.HTTPResponse(sock)
                    response.begin()
                    sock.stream.tracking = True
                    handler = feed.PublicHttpsRedirect()

                    class Parent:
                        def open(self, request, timeout=None):
                            return request

                    handler.parent = Parent()
                    request = urllib.request.Request("https://example.com/start")
                    request.timeout = 6
                    with patch.object(feed, "validate_public_host"):
                        redirected = handler.http_error_302(
                            request, response, code, "Redirect", response.headers
                        )

                    self.assertEqual(redirected.full_url, "https://example.com/next")
                    self.assertEqual(sock.stream.body_bytes_read, 0)
                    self.assertTrue(response.isclosed())

    def test_network_commands_receive_token_urls_only_via_stdin(self):
        url = "https://example.com/private/path-secret?token=query-secret"
        for operation in ("feed", "article", "image"):
            output = io.StringIO()
            with self.subTest(operation=operation), \
                    patch.object(feed.sys, "stdin", io.StringIO(json.dumps({"url": url}) + "\n")), \
                    patch.object(feed, "fetch", return_value=(b"<rss><channel/></rss>", url)) as fetch, \
                    patch.object(feed, "article", return_value={"ok": True}) as article, \
                    patch.object(feed, "image", return_value={"ok": True}) as image, \
                    redirect_stdout(output):
                self.assertEqual(feed.main(["feed.py", operation]), 0)
                {"feed": fetch, "article": article, "image": image}[operation].assert_called_once_with(url)
                self.assertTrue(json.loads(output.getvalue())["ok"])

    def test_network_errors_do_not_echo_tokens(self):
        url = "https://example.com/private/path-secret?token=query-secret"
        for operation, function in (("feed", "fetch"), ("article", "article"), ("image", "image")):
            output = io.StringIO()
            with self.subTest(operation=operation), \
                    patch.object(feed.sys, "stdin", io.StringIO(json.dumps({"url": url}) + "\n")), \
                    patch.object(feed, function, side_effect=ValueError("Server echoed " + url)), \
                    redirect_stdout(output):
                self.assertEqual(feed.main(["feed.py", operation]), 1)
                result = json.loads(output.getvalue())
                self.assertFalse(result["ok"])
                self.assertNotIn("secret", output.getvalue())

    def test_real_helper_cmdline_has_no_url_and_rejects_argv_urls(self):
        url = "https://localhost/path-secret?token=query-secret"
        for operation in ("feed", "article", "image"):
            with self.subTest(operation=operation), subprocess.Popen(
                    ["python3", str(MODULE_PATH), operation], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                command = Path(f"/proc/{process.pid}/cmdline").read_bytes()
                self.assertNotIn(b"secret", command)
                self.assertNotIn(b"https://", command)
                output, error = process.communicate(json.dumps({"url": url}) + "\n", timeout=5)
                self.assertEqual(process.returncode, 1)
                self.assertFalse(json.loads(output)["ok"])
                self.assertNotIn("secret", output + error)
            rejected = subprocess.run(["python3", str(MODULE_PATH), operation, url],
                                      text=True, capture_output=True, timeout=5)
            self.assertEqual(rejected.returncode, 1)
            self.assertNotIn("secret", rejected.stdout + rejected.stderr)

    def test_network_stdin_rejects_malformed_and_oversized_requests(self):
        for request in ("invalid", "null", '{"url":123}', json.dumps({"url": "x" * 17000})):
            output = io.StringIO()
            with self.subTest(request=request[:30]), \
                    patch.object(feed.sys, "stdin", io.StringIO(request + "\n")), \
                    patch.object(feed, "fetch") as fetch, redirect_stdout(output):
                self.assertEqual(feed.main(["feed.py", "feed"]), 1)
                fetch.assert_not_called()
                self.assertFalse(json.loads(output.getvalue())["ok"])

    def test_only_https_public_urls_are_accepted(self):
        for url in (
            "http://example.com/feed",
            "https://localhost/feed",
            "https://127.0.0.1/feed",
            "https://example.com:444/feed",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                feed.safe_url(url)

    def test_rss_entries_are_plain_text_and_limited(self):
        xml = b"""<rss><channel><title>Daily</title><item>
          <title><![CDATA[<img src=x onerror=alert(1)> Hello]]></title>
          <link>https://example.com/story</link>
          <description><![CDATA[<p>Text <b>here</b><script>bad()</script></p>]]></description>
          <media:thumbnail xmlns:media="urn:media" url="https://example.com/image.jpg"/>
        </item></channel></rss>"""
        result = feed.parse_feed(xml, "https://example.com/feed")
        self.assertEqual(result["title"], "Daily")
        self.assertEqual(result["items"][0]["id"], "https://example.com/story")
        self.assertNotIn("<img", result["items"][0]["title"])
        self.assertNotIn("bad()", result["items"][0]["content"])
        self.assertEqual(result["items"][0]["image"], "https://example.com/image.jpg")

    def test_html_content_drops_script_text(self):
        self.assertEqual(feed.plain_text("<p>Good</p><script>secret</script>"), "Good")

    def test_article_extraction_prefers_content_and_drops_chrome(self):
        parser = feed.ArticleText()
        parser.feed("""<html><nav><p>Menu</p></nav><main><article>
        <h1>Title</h1><p>First paragraph &lt;literal&gt;.</p>
        <aside><p>Advertisement</p></aside><p>Second paragraph.</p>
        <script>secret</script></article></main><footer><p>Legal</p></footer></html>""")
        text = parser.content()
        self.assertIn("First paragraph <literal>.", text)
        self.assertIn("Second paragraph.", text)
        for chrome in ("Menu", "Advertisement", "secret", "Legal"):
            self.assertNotIn(chrome, text)

    def test_article_extraction_falls_back_to_paragraphs(self):
        parser = feed.ArticleText()
        parser.feed("<body><div>Unrelated controls</div><p>Readable paragraph.</p></body>")
        self.assertEqual(parser.content(), "Readable paragraph.")

    def test_nested_article_attack_is_rejected_under_memory_limit(self):
        script = """
import resource, sys
resource.setrlimit(resource.RLIMIT_AS, (128 * 1024 * 1024, 128 * 1024 * 1024))
sys.path.insert(0, sys.argv[1])
from feed import ArticleText, ArticleLimitError
parser = ArticleText()
try:
    parser.feed('<article>x' * 40000 + '</article>' * 40000)
except ArticleLimitError:
    assert len(parser.stack) <= parser.MAX_DEPTH
    assert parser.fragments <= parser.MAX_FRAGMENTS
    assert parser.retained_text <= parser.MAX_RETAINED_TEXT
    print('bounded rejection')
else:
    raise AssertionError('Attack was not rejected')
"""
        result = subprocess.run(["python3", "-c", script, str(MODULE_PATH.parent)],
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("bounded rejection", result.stdout)

    def test_article_candidate_fragment_text_and_node_budgets(self):
        cases = (
            "<article>x</article>" * 257,
            "<article>" + "<span>x</span>" * 17000 + "</article>",
            "<article><article>" + "x" * (600 * 1024) + "</article></article>",
            "<br>" * 50001,
        )
        for html in cases:
            parser = feed.ArticleText()
            with self.subTest(size=len(html)), self.assertRaises(feed.ArticleLimitError):
                parser.feed(html)
            self.assertLessEqual(len(parser.stack), parser.MAX_DEPTH)
            self.assertLessEqual(len(parser.candidates), parser.MAX_CANDIDATES)
            self.assertLessEqual(parser.fragments, parser.MAX_FRAGMENTS)
            self.assertLessEqual(parser.retained_text, parser.MAX_RETAINED_TEXT)

    def test_article_limit_failure_is_explicit_and_token_safe(self):
        url = "https://example.com/private?token=secret"
        output = io.StringIO()
        with patch.object(feed.sys, "stdin", io.StringIO(json.dumps({"url": url}) + "\n")), \
                patch.object(feed, "fetch", return_value=(b"<article>x" * 40000, url)), \
                redirect_stdout(output):
            self.assertEqual(feed.main(["feed.py", "article"]), 1)
        result = json.loads(output.getvalue())
        self.assertFalse(result["ok"])
        self.assertIn("safe extraction limits", result["error"])
        self.assertNotIn("secret", output.getvalue())

    def test_video_enclosure_does_not_hide_embedded_thumbnail(self):
        xml = b"""<rss xmlns:content="urn:content"><channel><item>
          <title>Story</title><link>https://example.com/story</link>
          <description>Short summary without an image.</description>
          <enclosure url="https://example.com/trailer.webm" type="video/webm"/>
          <content:encoded><![CDATA[<img src="/cover.jpg">]]></content:encoded>
        </item></channel></rss>"""
        result = feed.parse_feed(xml, "https://example.com/feed")
        self.assertEqual(result["items"][0]["image"], "https://example.com/cover.jpg")

    def test_video_only_entry_has_no_thumbnail(self):
        xml = b"""<rss><channel><item>
          <title>Story</title><link>https://example.com/story</link>
          <enclosure url="https://example.com/trailer.webm"/>
          <description><![CDATA[<img src="https://127.0.0.1/private.jpg">]]></description>
        </item></channel></rss>"""
        result = feed.parse_feed(xml, "https://example.com/feed")
        self.assertEqual(result["items"][0]["image"], "")

    def test_opml_import_preserves_folders_and_upgrades_http(self):
        xml = b"""<opml version="2.0"><body><outline text="Technology">
          <outline text="Daily &amp; More" xmlUrl="http://example.com/feed"/>
          <outline text="Duplicate" xmlUrl="https://example.com/feed"/>
        </outline></body></opml>"""
        subscriptions = feed.parse_opml(xml)
        self.assertEqual(subscriptions, [{"title": "Daily & More", "url": "https://example.com/feed", "folder": "Technology"}])

    def test_opml_rejects_private_urls_and_wrong_documents(self):
        for xml in (
            b'<opml><body><outline xmlUrl="https://127.0.0.1/feed"/></body></opml>',
            b'<html><body/></html>',
            b'<opml><body/></opml>',
        ):
            with self.subTest(xml=xml), self.assertRaises(ValueError):
                feed.parse_opml(xml)

    def test_opml_export_round_trip_and_no_overwrite(self):
        subscriptions = [{"title": "Daily <News>", "url": "https://example.com/feed", "folder": "A & B"}]
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "state.json"
            destination = Path(directory) / "feeds.opml"
            state_path.write_text(json.dumps({"feeds": subscriptions}))
            feed.export_opml(state_path, destination)
            self.assertEqual(feed.parse_opml(destination.read_bytes()), subscriptions)
            with self.assertRaises(FileExistsError):
                feed.export_opml(state_path, destination)


if __name__ == "__main__":
    unittest.main()
