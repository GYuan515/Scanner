# 依赖与许可证

原则：只用 MIT、BSD、Apache-2.0 这类宽松许可。新增依赖或模型时在这里记一笔。

核对日期：2026-11-16，数据来自 pub.dev 和各项目的 LICENSE 文件。

## Dart / Flutter 包

| 包 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| camera | 0.12.2 | BSD-3-Clause | 相机取景和拍照 |
| opencv_dart | 2.2.2 | Apache-2.0 | 图像处理（OpenCV 4.x 本身是 Apache-2.0） |
| flutter_onnxruntime | 1.9.0 | MIT | 端上模型推理（ONNX Runtime 本身是 MIT） |
| pdfrx | 2.12.0 | MIT | PDF 渲染和文本（PDFium 本身是 BSD-3/Apache-2.0） |
| pdf | 3.13.1 | Apache-2.0 | 生成 PDF，含可搜索 PDF 的文字层 |
| printing | 5.15.1 | Apache-2.0 | 打印（Android PrintManager / iOS AirPrint） |
| drift / drift_flutter | 2.35.4 / 0.3.1 | MIT | SQLite 数据库 |
| go_router | 18.1.4 | BSD-3-Clause | 路由 |
| flutter_riverpod | 3.5.0 | MIT | 状态管理 |
| image_picker | 1.2.4 | Apache-2.0 / BSD-3-Clause | 相册导入 |
| file_picker | 13.3.3 | MIT | 文件导入 |
| share_plus | 13.3.1 | BSD-3-Clause | 系统分享 |
| permission_handler | 13.0.2 | MIT | 权限申请 |
| local_auth | 3.0.2 | BSD-3-Clause | 指纹解锁 |
| crypto | 3.0.8 | BSD-3-Clause | 密码哈希（PBKDF2） |
| flutter_zxing | 3.1.0 | MIT | 二维码和条码识别（内含 zxing-cpp，Apache-2.0；zint，BSD-3-Clause） |
| url_launcher | 6.3.3 | BSD-3-Clause | 打开二维码里的链接 |
| pointycastle | 4.0.0 | MIT | PDF 加密用的 AES（AES-256，PDF 2.0 标准第 6 版） |
| vector_math | 2.4.x | BSD-3-Clause（Zlib 部分） | PDF 文字层的变换矩阵 |
| archive | 4.7.x | MIT | 生成 docx / xlsx（zip + XML） |

不用：`onnxruntime` 包（2024-03 之后没有更新）；`mobile_scanner`（Android 上依赖 ML Kit）。

## 模型

| 模型 | 来源 | 许可证 | 状态 |
|---|---|---|---|
| PP-OCRv5 mobile 检测、识别；PP-LCNet x0.25 文本行方向 | RapidAI/RapidOCR（ModelScope）的 ONNX 转换版 | Apache-2.0 | 已接入（P3），经 `app/tool/prepare_ocr_models.py` 改成 uint8 输入并精简输出 |
| PP-Structure 版面分析（CDLA，PicoDet）、SLANet+ 表格结构 | RapidAI/RapidLayout、RapidAI/RapidTable（ModelScope）的 ONNX 版 | Apache-2.0 | 已接入（P6），经 `app/tool/prepare_layout_models.py` 改成 uint8 输入、输出重命名。YOLOv8 / DocLayout-YOLO 系列是 AGPL，不用 |
| UVDoc | | 待确认 | P7 前确认 |
| LaMa | | Apache-2.0 | 待接入（P7） |

## 字体

只用于可搜索 PDF 的隐形文字层，导出时按用到的字符做子集。

| 字体 | 来源 | 许可证 |
|---|---|---|
| Roboto Regular | AOSP `external/roboto-fonts` | Apache-2.0 |
| Droid Sans Fallback Full | AOSP `frameworks/base/data/fonts` | Apache-2.0 |
