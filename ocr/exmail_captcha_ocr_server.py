import base64
import io
import json
import os
import random
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 17898

# RapidOCR's DBNet detection pass used to run on every request and cost ~478 ms
# of a ~640 ms total, because it upscales this 130x53 captcha to its 736 px
# minimum side before detecting. We never needed it: the characters are always
# the only ink on the image, so split_boxes() locates them with plain numpy in
# ~1 ms. Only the recognition session is used now, which is why the thread count
# below is tuned for small tensors instead of for detection.
#
# Measured on this 8-core box, whole-request mean over the 70-sample set:
#   1 thread 137 ms | 2 threads 88 | 3 threads 74 | 4 threads 73 | 6 threads 78 | 8 threads 83
# Beyond 4 the thread-sync overhead exceeds the compute saved, so using every
# logical core (the previous setting) was actively slower.
REC_THREADS = min(4, os.cpu_count() or 4)


def _tune_onnxruntime():
    """Force thread count and disable spin-waiting on every ONNX session.

    ORT intra-op worker threads busy-wait for their next task by default. We run
    three sessions per request (ddddocr default, ddddocr beta, RapidOCR
    recognition), so while one is inferring the other two keep spinning and
    steal the cores it needs. Disabling that took the whole request from 121 ms
    to 73 ms here, and inference output is bit-identical either way.

    ddddocr constructs its InferenceSession internally and exposes no way to
    pass session options, so wrapping the constructor is the only hook. Done
    before ddddocr/rapidocr are imported so it applies to their models too.
    """
    try:
        import onnxruntime as ort
    except Exception:
        return

    real_session = ort.InferenceSession

    class TunedSession(real_session):
        def __init__(self, path_or_bytes, sess_options=None, providers=None, **kwargs):
            options = sess_options or ort.SessionOptions()
            try:
                options.intra_op_num_threads = REC_THREADS
                options.inter_op_num_threads = 1
                options.add_session_config_entry("session.intra_op.allow_spinning", "0")
            except Exception:
                options = sess_options
            if providers is None:
                providers = ["CPUExecutionProvider"]
            super().__init__(path_or_bytes, sess_options=options, providers=providers, **kwargs)

    ort.InferenceSession = TunedSession


_tune_onnxruntime()

import ddddocr  # noqa: E402  (must follow _tune_onnxruntime)
import numpy as np  # noqa: E402
from PIL import Image, ImageDraw, ImageEnhance  # noqa: E402

try:
    from rapidocr_onnxruntime import RapidOCR
except Exception:
    RapidOCR = None


def _make_rapid():
    if RapidOCR is None:
        return None
    try:
        return RapidOCR(
            intra_op_num_threads=REC_THREADS,
            det_use_cuda=False,
            rec_use_cuda=False,
            cls_use_cuda=False,
        )
    except Exception:
        try:
            return RapidOCR(intra_op_num_threads=REC_THREADS)
        except Exception:
            return RapidOCR()


OCR = ddddocr.DdddOcr(show_ad=False)
OCR_BETA = ddddocr.DdddOcr(show_ad=False, beta=True)
RAPID = _make_rapid()
RNG = random.SystemRandom()
CONFUSIONS = str.maketrans({"0": "o", "O": "o", "9": "g"})

# The two ddddocr models and the RapidOCR batch are independent ONNX sessions and
# release the GIL during inference, so overlapping them hides the cheaper one.
POOL = ThreadPoolExecutor(max_workers=3, thread_name_prefix="ocr")


def clean_text(text):
    """只保留 ASCII 字母数字。

    不能用 str.isalnum()：它对任意 Unicode 字母数字都返回 True，所以西里尔、
    中文、希腊字符都能混进来。实测 rapidocr 的字符集确实会吐出这类字符
    （例：把一个 x 识别成西里尔 һ U+04BB），结果是服务端自认为给出了 4 字符
    答案，而油猴脚本用 /[^0-9a-zA-Z]/ 一过滤就只剩 3 个字符被判为无效。
    更麻烦的是大小写还原是按位置对齐的，串里混入会被下游剥掉的字符会让
    整个对齐错位。这里提前过滤掉，服务端和客户端的字符集就一致了。
    """
    return "".join(ch for ch in str(text or "") if ch.isascii() and ch.isalnum())[:6]


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


def flip_cost(position, base_char, crop_texts):
    """改掉第 position 位的大小写，要付多大代价。

    代价 = 该位 crop 证据的强度。证据强(置信度高)就不该动它，证据弱或
    无效就优先翻转。这样排序只依赖每张图自己的证据，不引入拿少量标注
    拟合出来的全局先验。

    关键：必须先确认 crop 认出的就是该位那个字母，否则不算证据。实测
    live_03 第3位 crop 给的是 "HM"(两个字符)、第4位是 "V"(字母都不对)，
    这些不是「该位是小写」的证据，只是识别失败；若按置信度计入代价，
    反而会把真正该翻转的位锁死。
    """
    if position >= len(crop_texts):
        return 0.0
    crop_text, confidence = crop_texts[position]
    crop_char = crop_text[:1]
    if len(crop_text) != 1 or identity_char(crop_char) != identity_char(base_char):
        return 0.0
    return float(confidence)


def order_variants(variants, anchor, crop_texts):
    """把大小写变体按「最可能是真值」排序。

    脚本每页最多提交 5 次(maxSubmitAttemptsPerPage)，每次换一个候选，所以
    候选顺序直接决定成功率。原来这里是 RNG.shuffle 随机洗牌，等于放弃排序,
    实测真值常被排到第 10/11/15 位，5 次重试根本吃不到。

    排序规则：先按与 anchor(当前最优猜测)的汉明距离升序 —— 实测真值与
    anchor 的距离全是 1~2，距离 1 只有 4 个变体，所以真值会很靠前。同距离
    内按「翻转代价」升序，即先翻证据最弱的位。
    """
    def key(variant):
        diff = [i for i in range(min(len(variant), len(anchor))) if variant[i] != anchor[i]]
        cost = sum(flip_cost(i, anchor[i], crop_texts) for i in diff)
        # 代价为主、距离为辅：证据都无效时翻两位可能比翻一个有强证据的位更该优先
        return (cost, len(diff))

    return sorted(variants, key=key)


def rapid_texts(image_bytes):
    """Whole-line reading via RapidOCR's full detect-then-recognise pipeline.

    Kept only so the benchmark scripts in .local/ can still measure the old path.
    The server uses rapid_pass(), which skips detection; see the note there.
    """
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


def char_canvas(image, box):
    """A character box centred on a fixed white canvas, as the recogniser expects."""
    crop = image.crop(box)
    canvas = Image.new("RGB", (64, 64), "white")
    crop.thumbnail((56, 56))
    canvas.paste(crop, ((64 - crop.width) // 2, (64 - crop.height) // 2))
    return np.array(canvas)


def rapid_pass(image):
    """Whole-line and per-character readings in a single recognition batch.

    Replaces RapidOCR's detect-then-recognise pipeline. Detection cost ~478 ms
    per image and, worse, found no text at all on 25 of our 70 samples, leaving
    the case-restoration logic with no signal. Cropping to the ink bounding box
    that split_boxes() already computes feeds the recogniser directly and reads
    61 of 70 - more coverage, ~19x cheaper.

    The line crop and the four character crops go in one text_rec() call. Every
    input is zero-padded to the same width regardless (max_wh_ratio has a floor
    of rec_image_shape[2]/rec_image_shape[1]), so batching them together yields
    byte-identical text and confidences to calling them separately, one less
    session round-trip.

    Returns (rapid_list, crop_texts) matching the old rapid_texts() /
    rapid_crop_texts() shapes.
    """
    if RAPID is None:
        return [], []
    try:
        boxes = split_boxes(image)
        if not boxes:
            return [], []
        line_box = (
            min(b[0] for b in boxes),
            min(b[1] for b in boxes),
            max(b[2] for b in boxes),
            max(b[3] for b in boxes),
        )
        batch = [np.array(image.crop(line_box))]
        batch.extend(char_canvas(image, box) for box in boxes)

        result, _elapsed = RAPID.text_rec(batch)
        line_text = clean_text(result[0][0])
        rapid_list = [line_text[:4]] if len(line_text) >= 4 else []
        crop_texts = [(signal_text(text), float(confidence)) for text, confidence in result[1:]]
        return rapid_list, crop_texts
    except Exception:
        return [], []


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


# 这些字母的大写和小写字形基本相同，只能靠「相对其他字符的高度」区分。
# 整行识别器会把行高归一化掉，所以它对这些字母吐出的大小写**不携带任何信息**，
# 只反映模型自身的全大写倾向（实测整行把 pgbp 读成 Psbp、zSPB 读成 ZSPB、
# ynyn 读成 YIny，首字母无一例外被抬成大写）。因此这些字母一律不信整行，
# 只信逐字符 crop —— crop 是在保留相对尺寸的小图上做的，才真正含高度信息。
SAME_SHAPE_CASE = frozenset("cosuvwxzpkmnyj")

# 实测 12 张真实验证码上，crop 投大写时：
#   真值确实大写的置信度 = 0.627 0.664 0.804 0.837 0.844 0.952（最低 0.627）
#   真值其实小写的置信度 = 0.540（唯一误报，也是最高）
# 两组不重叠，阈值取 0.60 可完全分开。
SAME_SHAPE_UPPER_CONF = 0.60


def crop_votes_upper(base_char, position, crop_texts, min_conf):
    """逐字符 crop 是否以足够置信度认为该位是大写。"""
    crop_text, confidence = crop_texts[position] if position < len(crop_texts) else ("", 0.0)
    crop_char = crop_text[:1]
    return (
        len(crop_text) == 1
        and crop_char.isupper()
        and identity_char(crop_char) == base_char
        and confidence >= min_conf
    )


def trust_upper(base_char, position, crop_texts):
    """整行/引擎信号投了大写时，是否采纳。

    同形字母必须由 crop 印证，因为整行信号对它们没有鉴别力；异形字母
    （b/d/e/g/h/q/r…）整行能真正看出字形差异，沿用原有的宽松策略。
    """
    if base_char in SAME_SHAPE_CASE:
        return crop_votes_upper(base_char, position, crop_texts, SAME_SHAPE_UPPER_CONF)
    if base_char == "d":
        return crop_votes_upper(base_char, position, crop_texts, 0.45)
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
        # 同形字母走统一的高阈值，否则这里的宽松默认值(0.25)会绕过 trust_upper
        # 的把关，把整行的全大写倾向重新放进结果。
        if base_char in SAME_SHAPE_CASE:
            threshold = SAME_SHAPE_UPPER_CONF
        elif base_char == "d":
            threshold = 0.45
        elif base_char == "f":
            threshold = 0.05
        else:
            threshold = 0.25
        if confidence >= threshold:
            output[index] = base_char.upper()


def enhanced_candidate(default, beta, rapid_list, crop_texts):
    base_source = default if len(default) == 4 else beta
    base = identity(base_source)[:4]
    if len(base) != 4:
        return ""
    output = list(base)
    for signal in [default, beta, *rapid_list]:
        apply_case_signal(output, base, signal, crop_texts)
    apply_crop_signal(output, base, crop_texts)
    return "".join(output)


def contrast_retry(image):
    """对比度增强后重读，仅用于主引擎吐不出 4 位时的兜底。

    删除线和空心描边字形会让首字符的笔画淡到主引擎直接漏读（live_05 的 'x'、
    live_12 的 'L' 都是这样丢的，输出只剩 3 位，长度检查不过、候选集为空）。
    拉高对比度后两张都能读回 4 位。

    实测 70 样本：无条件启用会让 5 张原本 4 位的样本退化成 3 位（对比度增强
    也会把相邻字符的笔画连到一起），所以只在主引擎已经失败时才试——那时没有
    可失去的东西。原本 4 位的输出一律不碰。
    """
    try:
        enhanced = ImageEnhance.Contrast(image).enhance(2.5)
        buffer = io.BytesIO()
        enhanced.save(buffer, format="PNG")
        return clean_text(OCR.classification(buffer.getvalue()))[:4]
    except Exception:
        return ""


def choose_code(image_bytes):
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    # Three independent ONNX sessions; each releases the GIL while inferring, so
    # running them concurrently costs about as much as the slowest one alone.
    future_default = POOL.submit(OCR.classification, image_bytes)
    future_beta = POOL.submit(OCR_BETA.classification, image_bytes)
    rapid_list, crop_texts = rapid_pass(image)
    default = clean_text(future_default.result())[:4]
    beta = signal_text(future_beta.result())[:4]

    # 两个引擎都凑不出 4 位时才走对比度兜底，代价是多一次识别（约 25ms），
    # 但此时原本的结果已经会被长度检查丢掉，没有可失去的东西。
    if len(default) != 4 and len(beta) != 4:
        retried = contrast_retry(image)
        if len(retried) == 4:
            default = retried

    candidates = []
    enhanced = enhanced_candidate(default, beta, rapid_list, crop_texts)
    add_candidate(candidates, enhanced)
    for text in rapid_list:
        add_candidate(candidates, signal_text(text))
    add_candidate(candidates, beta)
    add_candidate(candidates, default)

    base = default if len(default) == 4 else beta
    if len(base) == 4:
        upper_priority = [item for item in candidates if same_identity(base, item) and item != default]
        variants = order_variants(case_variants(base), enhanced or base, crop_texts)
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
    # Keep-alive: the userscript issues a fresh POST per captcha refresh, and on
    # Windows a new TCP connection per request adds avoidable latency.
    protocol_version = "HTTP/1.1"

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


def warmup():
    """Run one throwaway request through every model.

    ONNX Runtime defers a lot of allocation and kernel selection to the first
    Run() call, so without this the first real captcha of the session pays a
    one-off penalty of a few hundred ms - exactly when the user is waiting.

    The synthetic image must contain ink in four separate columns: on a blank
    image split_boxes() finds nothing and rapid_pass() returns early, leaving
    the recognition session cold, which is the expensive one.
    """
    canvas = Image.new("RGB", (130, 53), "white")
    draw = ImageDraw.Draw(canvas)
    for index in range(4):
        x = 12 + index * 28
        draw.ellipse((x, 12, x + 18, 40), outline=(0, 0, 160), width=3)
    buffer = io.BytesIO()
    canvas.save(buffer, format="PNG")
    try:
        choose_code(buffer.getvalue())
    except Exception:
        pass


def main():
    warmup()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"exmail captcha OCR server listening on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
