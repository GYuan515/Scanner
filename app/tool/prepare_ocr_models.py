"""Turns the RapidOCR PP-OCRv5 mobile ONNX models into the bundled assets.

Usage (from a venv with onnx, numpy, onnxruntime):
    python tool/prepare_ocr_models.py <download_dir> assets/models

Source: https://www.modelscope.cn/models/RapidAI/RapidOCR (Apache-2.0)
    onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx
    onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx
    onnx/PP-OCRv5/cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx

What changes, and why:
  * Input becomes uint8 NHWC BGR ("image"); the cast, transpose and
    normalisation move into the graph. The app runs inference through a
    platform channel, so this sends 1 byte per channel instead of 4, and the
    Dart side can hand over OpenCV pixel data without a float loop.
  * rec: ArgMax / ReduceMax over the 18385-class axis are appended. The raw
    output is N x T x 18385 floats (tens of MB per batch); greedy CTC only
    needs the best class and its probability per step.
  * det: the probability map is returned as uint8 (p * 255, rounded),
    a quarter of the size; 1/255 steps are far finer than the 0.3 / 0.5
    thresholds that consume it.
The numerical check at the end compares every model against the original.
"""

import sys
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]
HALF = [0.5, 0.5, 0.5]

MODELS = {
    # name: (source file, mean, std, fixed H, fixed W)
    'det': ('ch_PP-OCRv5_det_mobile.onnx', IMAGENET_MEAN, IMAGENET_STD, None, None),
    'rec': ('ch_PP-OCRv5_rec_mobile.onnx', HALF, HALF, 48, None),
    'cls': ('ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx', IMAGENET_MEAN, IMAGENET_STD, 80, 160),
}


def const(name, values, dtype=np.float32, shape=None):
    arr = np.asarray(values, dtype=dtype)
    if shape is not None:
        arr = arr.reshape(shape)
    return numpy_helper.from_array(arr, name)


def add_uint8_input(model, mean, std, h, w):
    g = model.graph
    old = g.input[0]
    old_name = old.name
    # Rename the original input so the new prefix can feed it.
    inner = old_name + '_normalized'
    for node in g.node:
        for i, n in enumerate(node.input):
            if n == old_name:
                node.input[i] = inner
    g.input.remove(old)

    dims = ['N', h if h else 'H', w if w else 'W', 3]
    new_in = helper.make_tensor_value_info('image', TensorProto.UINT8, dims)
    g.input.insert(0, new_in)

    scale = [1.0 / (255.0 * s) for s in std]
    bias = [-m / s for m, s in zip(mean, std)]
    g.initializer.extend([
        const('pre_scale', scale, shape=(1, 3, 1, 1)),
        const('pre_bias', bias, shape=(1, 3, 1, 1)),
    ])
    prefix = [
        helper.make_node('Cast', ['image'], ['pre_f32'], to=TensorProto.FLOAT),
        helper.make_node('Transpose', ['pre_f32'], ['pre_nchw'], perm=[0, 3, 1, 2]),
        helper.make_node('Mul', ['pre_nchw', 'pre_scale'], ['pre_scaled']),
        helper.make_node('Add', ['pre_scaled', 'pre_bias'], [inner]),
    ]
    for i, node in enumerate(prefix):
        g.node.insert(i, node)


def rec_outputs(model):
    g = model.graph
    raw = g.output[0].name
    g.output.remove(g.output[0])
    g.node.extend([
        helper.make_node('ArgMax', [raw], ['index_i64'], axis=2, keepdims=0),
        helper.make_node('Cast', ['index_i64'], ['index'], to=TensorProto.INT32),
        helper.make_node('ReduceMax', [raw], ['prob'], axes=[2], keepdims=0),
    ])
    g.output.extend([
        helper.make_tensor_value_info('index', TensorProto.INT32, ['N', 'T']),
        helper.make_tensor_value_info('prob', TensorProto.FLOAT, ['N', 'T']),
    ])


def det_outputs(model):
    g = model.graph
    raw = g.output[0].name
    g.output.remove(g.output[0])
    g.initializer.extend([const('post_255', [255.0]), const('post_half', [0.5])])
    g.node.extend([
        helper.make_node('Mul', [raw, 'post_255'], ['post_scaled']),
        helper.make_node('Add', ['post_scaled', 'post_half'], ['post_rounded']),
        helper.make_node('Cast', ['post_rounded'], ['prob_u8'], to=TensorProto.UINT8),
    ])
    g.output.extend([helper.make_tensor_value_info('prob_u8', TensorProto.UINT8, ['N', 1, 'H', 'W'])])


def rename_output(model, name):
    g = model.graph
    raw = g.output[0].name
    g.output.remove(g.output[0])
    g.node.extend([helper.make_node('Identity', [raw], [name])])
    g.output.extend([helper.make_tensor_value_info(name, TensorProto.FLOAT, ['N', 2])])


def check(name, src_path, dst_path, mean, std, h, w):
    import onnxruntime as ort

    rng = np.random.default_rng(0)
    hh, ww = h or 96, w or 320
    img = rng.integers(0, 256, size=(2, hh, ww, 3), dtype=np.uint8)
    x = ((img.astype(np.float32) / 255.0 - np.array(mean, np.float32)) / np.array(std, np.float32))
    x = x.transpose(0, 3, 1, 2).astype(np.float32)

    src = ort.InferenceSession(str(src_path), providers=['CPUExecutionProvider'])
    dst = ort.InferenceSession(str(dst_path), providers=['CPUExecutionProvider'])
    ref = src.run(None, {src.get_inputs()[0].name: x})[0]
    out = dst.run(None, {'image': img})

    if name == 'rec':
        index, prob = out
        assert np.array_equal(index, ref.argmax(axis=2).astype(np.int32)), 'rec index mismatch'
        assert np.allclose(prob, ref.max(axis=2), atol=1e-4), 'rec prob mismatch'
    elif name == 'det':
        expected = np.floor(ref * 255.0 + 0.5).astype(np.uint8)
        assert np.abs(out[0].astype(int) - expected.astype(int)).max() <= 1, 'det map mismatch'
    else:
        assert np.allclose(out[0], ref, atol=1e-4), 'cls mismatch'
    print(f'  {name}: matches the original model')


def main():
    src_dir, dst_dir = Path(sys.argv[1]), Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)
    for name, (file, mean, std, h, w) in MODELS.items():
        model = onnx.load(str(src_dir / file))
        if name == 'rec':
            chars = next(p.value for p in model.metadata_props if p.key == 'character')
            keys = chars.split('\n')
            (dst_dir / 'ocr_keys.txt').write_text('\n'.join(keys), encoding='utf-8')
            print(f'  rec: {len(keys)} characters')
        add_uint8_input(model, mean, std, h, w)
        if name == 'rec':
            rec_outputs(model)
        elif name == 'det':
            det_outputs(model)
        else:
            rename_output(model, 'prob')
        del model.metadata_props[:]  # the 37 KB character list now lives in ocr_keys.txt
        onnx.checker.check_model(model)
        out = dst_dir / f'ocr_{name}.onnx'
        onnx.save(model, str(out))
        check(name, src_dir / file, out, mean, std, h, w)


if __name__ == '__main__':
    main()
