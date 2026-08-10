import base64
import http.client
import io
import json
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ocr"))

import exmail_captcha_ocr_server as server  # noqa: E402


def png_bytes():
    buffer = io.BytesIO()
    Image.new("RGB", (16, 8), "white").save(buffer, format="PNG")
    return buffer.getvalue()


class TextAndImageHelperTests(unittest.TestCase):
    def test_clean_text_only_keeps_ascii_alphanumeric(self):
        self.assertEqual(server.clean_text(" A\u4e2db-1\u04bb_Z "), "Ab1Z")

    def test_split_boxes_rejects_invalid_count_and_blank_image(self):
        image = Image.new("RGB", (20, 10), "white")
        self.assertEqual(server.split_boxes(image, 0), [])
        self.assertEqual(server.split_boxes(image, 1.5), [])
        self.assertEqual(server.split_boxes(image, 4), [])

    def test_load_image_decodes_valid_png(self):
        image = server.load_image(png_bytes())
        self.assertEqual(image.mode, "RGB")
        self.assertEqual(image.size, (16, 8))

    def test_load_image_marks_invalid_data(self):
        with self.assertRaises(server.InvalidImageError):
            server.load_image(b"not-an-image")


class RequestParsingTests(unittest.TestCase):
    def test_parse_content_length(self):
        self.assertEqual(server.parse_content_length("12"), 12)
        with self.assertRaisesRegex(server.RequestError, "\u7f3a\u5c11"):
            server.parse_content_length(None)
        with self.assertRaisesRegex(server.RequestError, "\u65e0\u6548"):
            server.parse_content_length("abc")
        with self.assertRaisesRegex(server.RequestError, "\u4e0d\u80fd\u4e3a\u7a7a"):
            server.parse_content_length("0")
        with self.assertRaises(server.RequestError) as context:
            server.parse_content_length(str(server.MAX_REQUEST_BYTES + 1))
        self.assertEqual(context.exception.status, 413)
        self.assertTrue(context.exception.close_connection)

    def test_parse_raw_base64(self):
        original = b"fixture-image"
        payload = json.dumps({"image": base64.b64encode(original).decode("ascii")}).encode("utf-8")
        self.assertEqual(server.parse_ocr_payload(payload), original)

    def test_parse_data_url_and_formatted_base64(self):
        original = b"fixture-image"
        encoded = base64.b64encode(original).decode("ascii")
        formatted = f"data:image/png;base64,{encoded[:4]}\n{encoded[4:]}"
        payload = json.dumps({"image": formatted}).encode("utf-8")
        self.assertEqual(server.parse_ocr_payload(payload), original)

    def test_rejects_invalid_json_shape_and_image(self):
        invalid_payloads = [
            b"{",
            json.dumps([]).encode("utf-8"),
            json.dumps({}).encode("utf-8"),
            json.dumps({"image": 123}).encode("utf-8"),
            json.dumps({"image": ""}).encode("utf-8"),
            json.dumps({"image": "%%%%"}).encode("utf-8"),
            json.dumps({"image": "data:image/png,AAAA"}).encode("utf-8"),
        ]
        for payload in invalid_payloads:
            with self.subTest(payload=payload), self.assertRaises(server.RequestError) as context:
                server.parse_ocr_payload(payload)
            self.assertEqual(context.exception.status, 400)


class HttpServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = server.OcrHttpServer((server.HOST, 0), server.Handler)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, name="test-ocr-http", daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.thread.join(timeout=5)
        cls.httpd.server_close()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection(server.HOST, self.port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            raw = response.read()
            payload = json.loads(raw.decode("utf-8"))
            return response.status, dict(response.getheaders()), payload
        finally:
            connection.close()

    def test_health_check_and_query_string(self):
        for path in ("/", "/?probe=1"):
            with self.subTest(path=path):
                status, headers, payload = self.request("GET", path)
                self.assertEqual(status, 200)
                self.assertEqual(payload, {"ok": True, "service": "exmail-captcha-ocr"})
                self.assertEqual(headers["Access-Control-Allow-Origin"], "*")

    def test_unknown_paths_return_404(self):
        for method in ("GET", "POST", "OPTIONS"):
            with self.subTest(method=method):
                status, headers, payload = self.request(method, "/missing")
                self.assertEqual(status, 404)
                self.assertFalse(payload["ok"])
                self.assertEqual(headers["Connection"], "close")

    def test_options_exposes_cors_methods(self):
        status, headers, payload = self.request("OPTIONS", "/ocr")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(headers["Access-Control-Allow-Methods"], "GET, POST, OPTIONS")
        self.assertEqual(headers["Access-Control-Allow-Headers"], "Content-Type")

    def test_post_accepts_raw_base64_and_data_url(self):
        image_bytes = b"fixture-image"
        encoded = base64.b64encode(image_bytes).decode("ascii")
        responses = (encoded, f"data:image/png;base64,{encoded}")
        expected = ("Ab1Z", ["Ab1Z", "aB1z"], "ab1z", "AB1Z")
        for image_value in responses:
            with self.subTest(image_value=image_value[:10]), mock.patch.object(
                server, "choose_code", return_value=expected
            ) as choose_code:
                body = json.dumps({"image": image_value}).encode("utf-8")
                status, _, payload = self.request(
                    "POST", "/ocr?source=test", body, {"Content-Type": "application/json"}
                )
                self.assertEqual(status, 200)
                self.assertEqual(payload["text"], "Ab1Z")
                self.assertEqual(payload["candidates"], ["Ab1Z", "aB1z"])
                choose_code.assert_called_once_with(image_bytes)

    def test_post_client_errors_return_400(self):
        cases = (
            b"{",
            json.dumps([]).encode("utf-8"),
            json.dumps({}).encode("utf-8"),
            json.dumps({"image": "%%%%"}).encode("utf-8"),
        )
        for body in cases:
            with self.subTest(body=body):
                status, _, payload = self.request("POST", "/ocr", body, {"Content-Type": "application/json"})
                self.assertEqual(status, 400)
                self.assertFalse(payload["ok"])

    def test_post_rejects_invalid_image_with_400(self):
        image_value = base64.b64encode(b"not-an-image").decode("ascii")
        body = json.dumps({"image": image_value}).encode("utf-8")
        status, _, payload = self.request("POST", "/ocr", body, {"Content-Type": "application/json"})
        self.assertEqual(status, 400)
        self.assertIn("\u56fe\u7247", payload["error"])

    def test_post_limits_request_size_with_413(self):
        connection = http.client.HTTPConnection(server.HOST, self.port, timeout=5)
        try:
            connection.putrequest("POST", "/ocr")
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", str(server.MAX_REQUEST_BYTES + 1))
            connection.endheaders()
            response = connection.getresponse()
            payload = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 413)
            self.assertFalse(payload["ok"])
            self.assertEqual(response.getheader("Connection"), "close")
        finally:
            connection.close()

    def test_internal_ocr_error_returns_500(self):
        encoded = base64.b64encode(b"fixture-image").decode("ascii")
        body = json.dumps({"image": encoded}).encode("utf-8")
        captured = io.StringIO()
        with mock.patch.object(server, "choose_code", side_effect=RuntimeError("inference failed")), mock.patch.object(
            server.sys, "stderr", captured
        ):
            status, _, payload = self.request("POST", "/ocr", body, {"Content-Type": "application/json"})
        self.assertEqual(status, 500)
        self.assertEqual(payload, {"ok": False, "error": "OCR \u8bc6\u522b\u5931\u8d25"})
        self.assertIn("inference failed", captured.getvalue())


class LifecycleTests(unittest.TestCase):
    def test_warmup_propagates_model_failure(self):
        with mock.patch.object(server, "choose_code", side_effect=RuntimeError("warmup failed")):
            with self.assertRaisesRegex(RuntimeError, "warmup failed"):
                server.warmup()

    def test_second_server_cannot_bind_same_port(self):
        first = server.OcrHttpServer((server.HOST, 0), server.Handler)
        port = first.server_address[1]
        second = None
        try:
            with self.assertRaises(OSError):
                second = server.OcrHttpServer((server.HOST, port), server.Handler)
        finally:
            if second is not None:
                second.server_close()
            first.server_close()

    def test_port_can_be_rebound_after_close(self):
        first = server.OcrHttpServer((server.HOST, 0), server.Handler)
        port = first.server_address[1]
        first.server_close()
        replacement = server.OcrHttpServer((server.HOST, port), server.Handler)
        replacement.server_close()

    def test_port_can_be_rebound_after_serving_request(self):
        first = server.OcrHttpServer((server.HOST, 0), server.Handler)
        port = first.server_address[1]
        thread = threading.Thread(target=first.serve_forever, daemon=True)
        thread.start()
        connection = http.client.HTTPConnection(server.HOST, port, timeout=5)
        try:
            connection.request("GET", "/")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            response.read()
        finally:
            connection.close()
            first.shutdown()
            thread.join(timeout=5)
            first.server_close()
        replacement = server.OcrHttpServer((server.HOST, port), server.Handler)
        replacement.server_close()


if __name__ == "__main__":
    unittest.main()
