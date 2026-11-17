"""Turns the layout and table-structure models into bundled assets.

Usage (same venv as prepare_ocr_models.py):
    python tool/prepare_layout_models.py <download_dir> assets/models

Sources (Apache-2.0, PaddleOCR / PP-Structure via RapidAI):
    RapidAI/RapidLayout  onnx/pp_layout/layout_cdla.onnx   -> layout.onnx
    RapidAI/RapidTable   slanet-plus.onnx                  -> table.onnx

Like the OCR models, the input becomes uint8 NHWC BGR ("image") with the
ImageNet normalisation inside the graph. Outputs are small and kept as
they are. The class names / structure tokens from the model metadata are
written next to them (layout_labels.txt, table_tokens.txt).
"""

import sys
from pathlib import Path

import numpy as np
import onnx

from prepare_ocr_models import IMAGENET_MEAN, IMAGENET_STD, add_uint8_input

MODELS = {
    # name: (source, fixed H, fixed W, labels file, output names in graph order)
    'layout': ('layout_cdla.onnx', 800, 608, 'layout_labels.txt',
               ['score8', 'score16', 'score32', 'score64', 'box8', 'box16', 'box32', 'box64']),
    'table': ('slanet-plus.onnx', 488, 488, 'table_tokens.txt', ['loc', 'probs']),
}


def rename_outputs(model, names):
    """Gives the outputs stable names: the app reads them by name, and the
    exported ones (transpose_0.tmp_0, ...) say nothing about their role."""
    from onnx import helper
    g = model.graph
    old = list(g.output)
    assert len(old) == len(names), (len(old), names)
    for o, n in zip(old, names):
        g.node.append(helper.make_node('Identity', [o.name], [n]))
        g.output.remove(o)
        new = onnx.ValueInfoProto()
        new.CopyFrom(o)
        new.name = n
        g.output.append(new)


def check(src_path, dst_path, h, w):
    import onnxruntime as ort

    rng = np.random.default_rng(1)
    img = rng.integers(0, 256, size=(1, h, w, 3), dtype=np.uint8)
    x = ((img.astype(np.float32) / 255.0 - np.array(IMAGENET_MEAN, np.float32)) / np.array(IMAGENET_STD, np.float32))
    x = x.transpose(0, 3, 1, 2).astype(np.float32)
    src = ort.InferenceSession(str(src_path), providers=['CPUExecutionProvider'])
    dst = ort.InferenceSession(str(dst_path), providers=['CPUExecutionProvider'])
    ref = src.run(None, {src.get_inputs()[0].name: x})
    out = dst.run(None, {'image': img})
    for a, b in zip(ref, out):
        assert a.shape == b.shape, (a.shape, b.shape)
        assert np.allclose(a, b, atol=1e-3), float(np.abs(a - b).max())
    print(f'  {dst_path.name}: matches the original ({len(out)} outputs)')


def main():
    src_dir, dst_dir = Path(sys.argv[1]), Path(sys.argv[2])
    for name, (file, h, w, labels, outputs) in MODELS.items():
        model = onnx.load(str(src_dir / file))
        chars = next(p.value for p in model.metadata_props if p.key == 'character')
        # The metadata uses CRLF; write LF-only lines (newline='' stops
        # Python from turning them back into CRLF on Windows).
        lines = [c for c in chars.splitlines() if c != '']
        with open(dst_dir / labels, 'w', encoding='utf-8', newline='') as fh:
            fh.write(chr(10).join(lines))
        add_uint8_input(model, IMAGENET_MEAN, IMAGENET_STD, h, w)
        rename_outputs(model, outputs)
        del model.metadata_props[:]
        onnx.checker.check_model(model)
        out = dst_dir / f'{name}.onnx'
        onnx.save(model, str(out))
        check(src_dir / file, out, h, w)
        print(f'  outputs: {[o.name for o in model.graph.output]}')
        print(f'  {labels}: {len(chars.splitlines())} entries')


if __name__ == '__main__':
    main()
