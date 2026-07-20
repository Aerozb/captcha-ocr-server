import base64
import io
import json
import random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ddddocr
import numpy as np
from PIL import Image

try:
    from rapidocr_onnxruntime import RapidOCR
except Exception:
    RapidOCR = None


HOST = "127.0.0.1"
PORT = 17898
OCR = ddddocr.DdddOcr(show_ad=False)
OCR_BETA = ddddocr.DdddOcr(show_ad=False, beta=True)
RAPID = RapidOCR() if RapidOCR else None
RNG = random.SystemRandom()
CONFUSIONS = str.maketrans({"0": "o", "O": "o", "9": "g"})


def clean_text(text):
    return "".join(ch for ch in str(text or "") if ch.isalnum())[:6]


def signal_text(text):
    return clean_text(text).replace("0", "O").replace("9", "g")


def identity_char(char):
    return {"0": "o", "O": "o", "9": "g"}.get(char, char).lower()


def identity(text):
    return clean_text(text).translate(CONFUSIONS).lower()


def same_identity(left, right):
    return len(left) == len(right) and identity(left) == identity(right)


def case_variants(text):
    pools = []
    for ch in clean_text(text)[:4]:
        if ch.isalpha():
            lower = ch.lower()
            upper = ch.upper()
            pools.append([lower] if lower == upper else [lower, upper])
        else:
            pools.append([ch])
    result = [""]
    for pool in pools:
        result = [prefix + ch for prefix in result for ch in pool]
    return result


def add_candidate(candidates, value):
    value = clean_text(value)[:4]
    if len(value) == 4 and value not in candidates:
        candidates.append(value)


def rapid_texts(image_bytes):
    if RAPID is None:
        return []
    try:
        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        result, _elapsed = RAPID(np.array(image))
        if not result:
            return []
        values = [clean_text(item[1]) for item in result if len(item) >= 2]
        joined = clean_text("".join(values))
        output = []
        if len(joined) >= 4:
            output.append(joined[:4])
        for value in values:
            if len(value) >= 4:
                output.append(value[:4])
        return output
    except Exception:
        return []


def mask_for(image):
    array = np.array(image.convert("RGB")).astype(np.int16)
    max_channel = array.max(axis=2)
    min_channel = array.min(axis=2)
    saturation = max_channel - min_channel
    return ((saturation > 20) & (max_channel < 250)) | (min_channel < 210)


def split_boxes(image, count=4):
    mask = mask_for(image)
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return []
    centers = np.linspace(xs.min(), xs.max(), count + 2)[1:-1]
    labels = None
    for _ in range(30):
        labels = np.argmin(np.abs(xs[:, None] - centers[None, :]), axis=1)
        new_centers = np.array([np.mean(xs[labels == i]) if np.any(labels == i) else centers[i] for i in range(count)])
        if np.max(np.abs(new_centers - centers)) < 0.1:
            break
        centers = new_centers
    boxes = []
    for index in np.argsort(centers):
        points = labels == index
        x = xs[points]
        y = ys[points]
        pad = 5
        boxes.append(
            (
                max(0, int(x.min()) - pad),
                max(0, int(y.min()) - pad),
                min(image.width, int(x.max()) + 1 + pad),
                min(image.height, int(y.max()) + 1 + pad),
            )
        )
    return boxes


def rapid_crop_texts(image):
    if RAPID is None:
        return []
    try:
        crops = []
        for box in split_boxes(image):
            crop = image.crop(box)
            canvas = Image.new("RGB", (64, 64), "white")
            crop.thumbnail((56, 56))
            canvas.paste(crop, ((64 - crop.width) // 2, (64 - crop.height) // 2))
            crops.append(np.array(canvas))
        if not crops:
            return []
        result, _elapsed = RAPID.text_rec(crops)
        return [(signal_text(text), float(confidence)) for text, confidence in result]
    except Exception:
        return []


def align_signal(base, text):
    text = signal_text(text)
    n = len(base)
    m = len(text)
    scores = [[0] * (m + 1) for _ in range(n + 1)]
    backtrack = [[None] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        scores[i][0] = scores[i - 1][0] - 2
        backtrack[i][0] = "up"
    for j in range(1, m + 1):
        scores[0][j] = scores[0][j - 1] - 1
        backtrack[0][j] = "left"
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            match = 4 if identity_char(base[i - 1]) == identity_char(text[j - 1]) else -2
            options = [
                (scores[i - 1][j - 1] + match, "diag"),
                (scores[i - 1][j] - 2, "up"),
                (scores[i][j - 1] - 1, "left"),
            ]
            scores[i][j], backtrack[i][j] = max(options)
    output = [None] * n
    i = n
    j = m
    while i > 0 or j > 0:
        step = backtrack[i][j]
        if step == "diag":
            output[i - 1] = text[j - 1]
            i -= 1
            j -= 1
        elif step == "up":
            i -= 1
        else:
            j -= 1
    return output


def trust_upper(base_char, position, crop_texts):
    crop_text, confidence = crop_texts[position] if position < len(crop_texts) else ("", 0.0)
    crop_char = crop_text[:1]
    crop_is_same_upper = (
        len(crop_text) == 1
        and crop_char.isupper()
        and identity_char(crop_char) == base_char
    )
    if base_char == "d":
        return crop_is_same_upper and confidence >= 0.45
    if base_char in "mns":
        return crop_is_same_upper and confidence >= 0.60
    return True


def apply_case_signal(output, base, signal, crop_texts):
    for index, char in enumerate(align_signal(base, signal)):
        if not char or identity_char(char) != base[index]:
            continue
        if char.isupper() and trust_upper(base[index], index, crop_texts):
            output[index] = base[index].upper()


def apply_crop_signal(output, base, crop_texts):
    for index, base_char in enumerate(base):
        if index >= len(crop_texts):
            continue
        crop_text, confidence = crop_texts[index]
        crop_char = crop_text[:1]
        if not crop_char or not crop_char.isupper() or identity_char(crop_char) != base_char:
            continue
        threshold = 0.25
        if base_char == "d":
            threshold = 0.45
        elif base_char in "mns":
            threshold = 0.60
        elif base_char == "f":
            threshold = 0.05
        if confidence >= threshold:
            output[index] = base_char.upper()


def enhanced_candidate(image_bytes, default, beta):
    base_source = default if len(default) == 4 else beta
    base = identity(base_source)[:4]
    if len(base) != 4:
        return ""
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    crop_texts = rapid_crop_texts(image)
    output = list(base)
    for signal in [default, beta, *rapid_texts(image_bytes)]:
        apply_case_signal(output, base, signal, crop_texts)
    apply_crop_signal(output, base, crop_texts)
    return "".join(output)


def choose_code(image_bytes):
    default = clean_text(OCR.classification(image_bytes))[:4]
    beta = signal_text(OCR_BETA.classification(image_bytes))[:4]

    candidates = []
    enhanced = enhanced_candidate(image_bytes, default, beta)
    add_candidate(candidates, enhanced)
    for text in rapid_texts(image_bytes):
        add_candidate(candidates, signal_text(text))
    add_candidate(candidates, beta)
    add_candidate(candidates, default)

    base = default if len(default) == 4 else beta
    if len(base) == 4:
        upper_priority = [item for item in candidates if same_identity(base, item) and item != default]
        variants = case_variants(base)
        RNG.shuffle(variants)
        for variant in variants:
            add_candidate(candidates, variant)

        if enhanced:
            chosen = enhanced
        # RapidOCR is the best available whole-line fallback when it agrees with ddddocr on letter identity.
        elif upper_priority:
            chosen = upper_priority[0]
        elif variants:
            chosen = variants[0]
        else:
            chosen = default
    else:
        chosen = candidates[0] if candidates else default

    return chosen, candidates, default, beta


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send_json(200, {"ok": True})

    def do_GET(self):
        self._send_json(200, {"ok": True, "service": "exmail-captcha-ocr"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            image = payload.get("image", "")
            if "," in image:
                image = image.split(",", 1)[1]
            image_bytes = base64.b64decode(image)
            text, candidates, default, beta = choose_code(image_bytes)
            self._send_json(200, {"ok": True, "text": text, "candidates": candidates, "default": default, "beta": beta})
        except Exception as exc:
            self._send_json(500, {"ok": False, "error": str(exc)})

    def log_message(self, _format, *args):
        return


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"exmail captcha OCR server listening on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
