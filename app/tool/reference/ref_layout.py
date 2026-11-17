"""Reference layout + table pipeline in Python (mirrors RapidLayout /
RapidTable), used to check the Dart port. Not shipped.

    python ref_layout.py make <page.jpg>
    python ref_layout.py run <models_dir> <page.jpg> <fixture_dir>
The run writes the raw model outputs and the expected decoded results to
<fixture_dir> so Dart tests can replay them without ONNX Runtime.
"""
import json
import sys
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort


def make(path):
    from PIL import Image, ImageDraw, ImageFont
    W, H = 1240, 1754
    img = Image.new('RGB', (W, H), 'white')
    d = ImageDraw.Draw(img)
    f = lambda name, size: ImageFont.truetype(f'C:/Windows/Fonts/{name}', size)
    d.text((W // 2 - 260, 110), '年度工作总结报告', fill='black', font=f('simhei.ttf', 64))
    body = f('simsun.ttc', 30)
    para1 = ['本报告总结了本年度的主要工作情况，包括项目进展、人员变动、经费使用等方面的内容。',
             '全年共完成重点项目八个，比上年增加两个，整体完成率达到百分之九十五以上。']
    y = 260
    for line in para1:
        d.text((110, y), line[:38], fill='black', font=body)
        y += 48
        if len(line) > 38:
            d.text((110, y), line[38:], fill='black', font=body)
            y += 48
    y += 40
    d.text((110, y), '表 1  各季度经费使用情况（万元）', fill='black', font=f('simhei.ttf', 30))
    y += 60
    # Table: header row with a merged cell spanning two columns.
    x0, cols, rows, rh = 110, [220, 230, 230, 330], 5, 64
    x_edges = [x0]
    for c in cols:
        x_edges.append(x_edges[-1] + c)
    y_edges = [y + r * rh for r in range(rows + 1)]
    for yy in y_edges:
        d.line([(x_edges[0], yy), (x_edges[-1], yy)], fill='black', width=3)
    for i, xx in enumerate(x_edges):
        if i == 2:  # merged header: no line between col 1 and 2 in the first row
            d.line([(xx, y_edges[1]), (xx, y_edges[-1])], fill='black', width=3)
        else:
            d.line([(xx, y_edges[0]), (xx, y_edges[-1])], fill='black', width=3)
    cell = f('simsun.ttc', 28)
    header = ['季度', '预算与支出', None, '备注']
    data = [['第一季度', '120', '115', '正常'],
            ['第二季度', '150', '162', '超支 8%'],
            ['第三季度', '130', '128', '正常'],
            ['第四季度', '160', '149', '结余']]
    def put(r, c, text, span=1):
        cx0, cx1 = x_edges[c], x_edges[c + span]
        tw = d.textlength(text, font=cell)
        d.text(((cx0 + cx1 - tw) / 2, y_edges[r] + 16), text, fill='black', font=cell)
    put(0, 0, header[0]); put(0, 1, header[1], span=2); put(0, 3, header[3])
    for r, row in enumerate(data, start=1):
        for c, t in enumerate(row):
            put(r, c, t)
    y = y_edges[-1] + 70
    # Figure: a simple bar chart drawn with shapes.
    d.rectangle([(300, y), (940, y + 360)], outline='black', width=3)
    for i, h in enumerate([120, 200, 160, 260]):
        d.rectangle([(360 + i * 140, y + 340 - h), (440 + i * 140, y + 340)], fill=(70 + i * 40, 120, 200))
    d.text((480, y + 380), '图 1  季度支出对比', fill='black', font=f('simhei.ttf', 28))
    y += 460
    for line in ['下一年度将继续加强预算管理，提高经费使用效率。', '各部门应按季度提交执行情况报告。']:
        d.text((110, y), line, fill='black', font=body)
        y += 48
    img.save(path, quality=92)


# ------------------------------------------------------------------ layout

LAYOUT_H, LAYOUT_W, STRIDES = 800, 608, [8, 16, 32, 64]


def layout_post(outs, ori_h, ori_w, labels, conf=0.5, iou=0.5):
    scores_l, boxes_l = outs[:4], outs[4:]
    reg_max = boxes_l[0].shape[-1] // 4 - 1
    all_boxes, all_scores = [], []
    for stride, dist, score in zip(STRIDES, boxes_l, scores_l):
        dist, score = dist[0], score[0]
        fh, fw = int(np.ceil(LAYOUT_H / stride)), int(np.ceil(LAYOUT_W / stride))
        ww, hh = np.meshgrid(np.arange(fw), np.arange(fh))
        cx, cy = (ww.flatten() + 0.5) * stride, (hh.flatten() + 0.5) * stride
        d = dist.reshape(-1, reg_max + 1)
        d = np.exp(d - d.max(axis=1, keepdims=True))
        d = d / d.sum(axis=1, keepdims=True)
        d = (d * np.arange(reg_max + 1)).sum(axis=1).reshape(-1, 4) * stride
        top = np.argsort(score.max(axis=1))[::-1][:1000]
        boxes = np.stack([cx - d[:, 0], cy - d[:, 1], cx + d[:, 2], cy + d[:, 3]], axis=1)[top]
        all_boxes.append(boxes)
        all_scores.append(score[top])
    boxes = np.concatenate(all_boxes)
    scores = np.concatenate(all_scores)
    out = []
    for c in range(scores.shape[1]):
        p = scores[:, c]
        m = p > conf
        if not m.any():
            continue
        bp = np.concatenate([boxes[m], p[m][:, None]], axis=1)
        order = np.argsort(bp[:, 4])[::-1]
        bp = bp[order]
        keep = []
        while len(bp):
            keep.append(bp[0])
            if len(keep) >= 100:
                break
            rest = bp[1:]
            xx1 = np.maximum(bp[0, 0], rest[:, 0]); yy1 = np.maximum(bp[0, 1], rest[:, 1])
            xx2 = np.minimum(bp[0, 2], rest[:, 2]); yy2 = np.minimum(bp[0, 3], rest[:, 3])
            inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
            a0 = (bp[0, 2] - bp[0, 0]) * (bp[0, 3] - bp[0, 1])
            ar = (rest[:, 2] - rest[:, 0]) * (rest[:, 3] - rest[:, 1])
            bp = rest[inter / (a0 + ar - inter + 1e-5) <= iou]
        sx, sy = ori_w / LAYOUT_W, ori_h / LAYOUT_H
        for k in keep:
            x1, y1, x2, y2 = np.clip(k[0], 0, LAYOUT_W) * sx, np.clip(k[1], 0, LAYOUT_H) * sy, np.clip(k[2], 0, LAYOUT_W) * sx, np.clip(k[3], 0, LAYOUT_H) * sy
            out.append({'label': labels[c], 'score': float(k[4]), 'box': [float(x1), float(y1), float(x2), float(y2)]})
    return out


# ------------------------------------------------------------------- table

TABLE = 488


def table_pre(crop):
    h, w = crop.shape[:2]
    ratio = TABLE / max(h, w)
    rh, rw = int(h * ratio), int(w * ratio)
    small = cv2.resize(crop, (rw, rh))
    pad = np.zeros((TABLE, TABLE, 3), np.uint8)
    pad[:] = np.round(np.array([0.485, 0.456, 0.406]) * 255).astype(np.uint8)  # normalises to ~0
    pad[:rh, :rw] = small
    return pad, ratio


def table_decode(loc, probs, ratio, tokens):
    chars = list(tokens)
    if '<td></td>' not in chars:
        chars.append('<td></td>')
    if '<td>' in chars:
        chars.remove('<td>')
    chars = ['sos'] + chars + ['eos']
    idx = probs[0].argmax(axis=1)
    structure, boxes = [], []
    for t, i in enumerate(idx):
        tok = chars[i]
        if t > 0 and tok == 'eos':
            break
        if tok in ('sos', 'eos'):
            continue
        if tok in ('<td>', '<td', '<td></td>'):
            boxes.append((loc[0, t] * TABLE / ratio).tolist())
        structure.append(tok)
    return structure, boxes


def run(models, page, fixture):
    sys.stdout.reconfigure(encoding='utf-8')
    fixture = Path(fixture)
    fixture.mkdir(parents=True, exist_ok=True)
    labels = Path(models, 'layout_labels.txt').read_text(encoding='utf-8').split('\n')
    tokens = Path(models, 'table_tokens.txt').read_text(encoding='utf-8').split('\n')
    img = cv2.imread(page)
    h, w = img.shape[:2]

    lay = ort.InferenceSession(f'{models}/layout.onnx', providers=['CPUExecutionProvider'])
    inp = cv2.resize(img, (LAYOUT_W, LAYOUT_H))
    outs = lay.run(None, {'image': inp[None]})
    for k, o in enumerate(outs):
        o.astype('<f4').tofile(fixture / f'layout_out{k}.bin')
    regions = layout_post(outs, h, w, labels)
    regions.sort(key=lambda r: (r['box'][1], r['box'][0]))
    for r in regions:
        print(f"{r['label']:15s} {r['score']:.2f} {[round(v) for v in r['box']]}")

    tables = [r for r in regions if r['label'] == 'table']
    expected = {'regions': regions, 'tables': []}
    tab = ort.InferenceSession(f'{models}/table.onnx', providers=['CPUExecutionProvider'])
    for n, t in enumerate(tables):
        x1, y1, x2, y2 = [int(round(v)) for v in t['box']]
        crop = img[y1:y2, x1:x2]
        pad, ratio = table_pre(crop)
        loc, probs = tab.run(None, {'image': pad[None]})
        loc.astype('<f4').tofile(fixture / f'table{n}_loc.bin')
        probs.astype('<f4').tofile(fixture / f'table{n}_probs.bin')
        structure, boxes = table_decode(loc, probs, ratio, tokens)
        print(''.join(structure))
        print(len(boxes), 'cells')
        expected['tables'].append({'crop': [x1, y1, x2, y2], 'ratio': ratio, 'steps': int(loc.shape[1]),
                                   'structure': structure, 'cells': boxes})
    (fixture / 'expected.json').write_text(json.dumps(expected, ensure_ascii=False, indent=1), encoding='utf-8')


if __name__ == '__main__':
    if sys.argv[1] == 'make':
        make(sys.argv[2])
    else:
        run(sys.argv[2], sys.argv[3], sys.argv[4])
