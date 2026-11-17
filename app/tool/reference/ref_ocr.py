"""Reference OCR pipeline in Python, mirroring what the Dart side does.

Used to check the converted models and to pick parameters; not shipped.
    python ref_ocr.py make <out.jpg>        # synthetic test page
    python ref_ocr.py run <models_dir> <image>
"""
import sys
import time

import cv2
import numpy as np
import onnxruntime as ort

LINES = [
    ('增值税专用发票', 'msyh.ttc', 64),
    ('购买方名称：上海某某科技有限公司', 'simsun.ttc', 36),
    ('纳税人识别号：91310000MA1K3XYZ8Q', 'simsun.ttc', 36),
    ('开票日期：2026年11月16日  金额 ¥1,280.50', 'msyh.ttc', 34),
    ('The quick brown fox jumps over the lazy dog.', 'arial.ttf', 34),
    ('备注：本发票仅用于测试文字识别效果，请勿报销。', 'simhei.ttf', 30),
    ('电话 021-6888 1234    邮箱 test@example.com', 'msyh.ttc', 28),
]


def make(path):
    from PIL import Image, ImageDraw, ImageFont
    img = Image.new('RGB', (1240, 1754), 'white')
    d = ImageDraw.Draw(img)
    y = 120
    for text, font, size in LINES:
        f = ImageFont.truetype(f'C:/Windows/Fonts/{font}', size)
        d.text((100, y), text, fill='black', font=f)
        y += int(size * 2.2)
    # A second column-ish block lower on the page.
    f = ImageFont.truetype('C:/Windows/Fonts/simsun.ttc', 32)
    d.text((100, 1300), '第一项', fill='black', font=f)
    d.text((700, 1300), '数量 3', fill='black', font=f)
    img.save(path, quality=92)


def det_resize(img, max_side=1600, min_side=32):
    h, w = img.shape[:2]
    r = min(1.0, max_side / max(h, w))
    nh = max(min_side, int(round(h * r / 32)) * 32)
    nw = max(min_side, int(round(w * r / 32)) * 32)
    return cv2.resize(img, (nw, nh)), nh / h, nw / w


def boxes_from_map(prob, thresh=0.3, box_thresh=0.5, unclip=1.6):
    mask = (prob > thresh * 255).astype(np.uint8)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    out = []
    for c in contours:
        if len(c) < 4:
            continue
        rect = cv2.minAreaRect(c)
        if min(rect[1]) < 3:
            continue
        box = cv2.boxPoints(rect)
        x0, y0 = np.floor(box.min(0)).astype(int).clip(0)
        x1, y1 = np.ceil(box.max(0)).astype(int)
        x1, y1 = min(x1, prob.shape[1] - 1), min(y1, prob.shape[0] - 1)
        m = np.zeros((y1 - y0 + 1, x1 - x0 + 1), np.uint8)
        cv2.fillPoly(m, [(box - [x0, y0]).astype(np.int32)], 1)
        score = cv2.mean(prob[y0:y1 + 1, x0:x1 + 1], m)[0] / 255
        if score < box_thresh:
            continue
        (cx, cy), (w, h), a = rect
        d = w * h * unclip / (2 * (w + h))
        rect2 = ((cx, cy), (w + 2 * d, h + 2 * d), a)
        if min(rect2[1]) < 5:
            continue
        out.append((order(cv2.boxPoints(rect2)), score))
    return out


def order(pts):
    pts = sorted(pts.tolist(), key=lambda p: p[0])
    left, right = sorted(pts[:2], key=lambda p: p[1]), sorted(pts[2:], key=lambda p: p[1])
    return np.array([left[0], right[0], right[1], left[1]], np.float32)


def crop(img, q):
    w = int(max(np.linalg.norm(q[0] - q[1]), np.linalg.norm(q[3] - q[2])))
    h = int(max(np.linalg.norm(q[0] - q[3]), np.linalg.norm(q[1] - q[2])))
    m = cv2.getPerspectiveTransform(q, np.float32([[0, 0], [w, 0], [w, h], [0, h]]))
    c = cv2.warpPerspective(img, m, (w, h), borderMode=cv2.BORDER_REPLICATE, flags=cv2.INTER_CUBIC)
    if h / max(w, 1) >= 1.5:
        c = np.rot90(c)
    return c


def run(models, path):
    sys.stdout.reconfigure(encoding="utf-8")
    opts = ort.SessionOptions()
    det = ort.InferenceSession(f'{models}/ocr_det.onnx', opts, providers=['CPUExecutionProvider'])
    rec = ort.InferenceSession(f'{models}/ocr_rec.onnx', opts, providers=['CPUExecutionProvider'])
    keys = ['<blank>'] + open(f'{models}/ocr_keys.txt', encoding='utf-8').read().split('\n') + [' ']
    img = cv2.imread(path)
    t = time.time()
    small, ry, rx = det_resize(img)
    prob = det.run(None, {'image': small[None]})[0][0, 0]
    found = boxes_from_map(prob)
    quads = [q / [rx, ry] for q, _ in found]
    quads.sort(key=lambda q: (q[0][1], q[0][0]))
    texts = []
    for q in quads:
        c = crop(img, q.astype(np.float32))
        h, w = c.shape[:2]
        nw = max(8, int(np.ceil(48 * w / h)))
        c = cv2.resize(c, (nw, 48))
        idx, p = rec.run(None, {'image': c[None]})
        s, last, ps = '', 0, []
        for i, pr in zip(idx[0], p[0]):
            if i != 0 and i != last:
                s += keys[i]
                ps.append(pr)
            last = i
        texts.append((s, float(np.mean(ps)) if ps else 0.0, q[0].round().tolist()))
    print(f'{len(quads)} boxes in {time.time() - t:.2f}s (det input {small.shape[1]}x{small.shape[0]})')
    sys.stdout.reconfigure(encoding='utf-8')
    for s, sc, p in texts:
        print(f'{sc:.3f} {p} {s}')


if __name__ == '__main__':
    if sys.argv[1] == 'make':
        make(sys.argv[2])
    else:
        run(sys.argv[2], sys.argv[3])
