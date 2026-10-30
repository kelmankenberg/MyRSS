import importlib.util
import unittest
import json
import tempfile
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "feed.py"
SPEC = importlib.util.spec_from_file_location("feed", MODULE_PATH)
feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed)


class FeedTests(unittest.TestCase):
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
