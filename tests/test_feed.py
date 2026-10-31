import importlib.util
import unittest
import json
import tempfile
import io
import subprocess
from contextlib import redirect_stdout
from unittest.mock import patch
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "feed.py"
SPEC = importlib.util.spec_from_file_location("feed", MODULE_PATH)
feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed)


class FeedTests(unittest.TestCase):
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
