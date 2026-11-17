"""Runs the reference OCR on an image and writes the app's OcrResult JSON."""
import json, sys
import cv2, numpy as np, onnxruntime as ort
sys.path.insert(0, '.')
from ref_ocr import det_resize, boxes_from_map, crop

models, image, out = sys.argv[1], sys.argv[2], sys.argv[3]
det = ort.InferenceSession(f'{models}/ocr_det.onnx', providers=['CPUExecutionProvider'])
rec = ort.InferenceSession(f'{models}/ocr_rec.onnx', providers=['CPUExecutionProvider'])
keys = ['<blank>'] + open(f'{models}/ocr_keys.txt', encoding='utf-8').read().split('\n') + [' ']
img = cv2.imread(image)
small, ry, rx = det_resize(img)
prob = det.run(None, {'image': small[None]})[0][0, 0]
rows = []
for q, _ in boxes_from_map(prob):
    q = (q / [rx, ry]).astype(np.float32)
    c = crop(img, q)
    h, w = c.shape[:2]
    c = cv2.resize(c, (max(8, int(np.ceil(48 * w / h))), 48))
    idx, p = rec.run(None, {'image': c[None]})
    s, last, ps = '', 0, []
    for i, pr in zip(idx[0], p[0]):
        if i != 0 and i != last:
            s += keys[i]; ps.append(float(pr))
        last = i
    if s.strip():
        rows.append([{'b': [round(float(v), 1) for v in q.flatten()], 't': s, 's': round(float(np.mean(ps)), 3)}])
json.dump({'w': img.shape[1], 'h': img.shape[0], 'rows': rows}, open(out, 'w', encoding='utf-8'), ensure_ascii=False)
print(len(rows), 'lines')
