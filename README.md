# 扫描（自用文档扫描 App）

一个完全离线的手机文档扫描 App，用 Flutter 写成，先做 Android，同一套代码再出 iOS。功能参照常见的商业扫描软件，全部基于宽松许可（MIT / BSD / Apache-2.0）的开源组件实现，不调用任何云服务。

## 功能

- **扫描**：相机实时识别纸张边框、画面稳定后自动拍摄；相册和文件导入；透视矫正；8 种滤镜（增强、去阴影、黑白、省墨等）
- **文件管理**：文件夹、标签、搜索（含识别出的文字）、最近打开、回收站、文档加锁（指纹 / 密码）
- **文字识别**：PP-OCRv5 端上识别，整页和框选识别，编辑、导出 TXT，可搜索 PDF，二维码和条码
- **阅读和标注**：阅读器（搜索、跳页、缩略图、打印），画笔、高亮、文字框、便签、签名（手写或从照片提取），水印，脱敏（真正删除像素）
- **PDF 工具箱**：合并、拆分、提取、整理页面、压缩、去密码、PDF 与图片互转，导出时可设 AES-256 打开密码
- **格式转换**：扫描件或 PDF 转 Word（标题、段落、表格、图片）和 Excel（表格，保留合并单元格）

## 目录

- `app/`：Flutter 工程
  - `lib/scan`：边缘检测、透视矫正、滤镜（OpenCV）
  - `lib/ocr`：文字识别流水线（ONNX Runtime，后台 isolate）
  - `lib/markup`：标注、签名、水印、脱敏
  - `lib/pdf`：PDF 工具和加密
  - `lib/convert`：版面分析、表格识别、docx / xlsx 生成
  - `assets/models`：打包进 App 的模型（由 `tool/` 里的脚本从原始模型转换而来）
  - `tool/`：模型转换脚本；`tool/reference/` 是对照用的 Python 参考实现
- `docs/roadmap.md`：功能规划和实现说明
- `docs/licenses.md`：所有依赖、模型、字体的来源和许可证

## 构建

- Android：`cd app && flutter build apk`（需要设置 `ANDROID_HOME`，并装好 NDK 和 CMake）
- iOS：没有 Mac 时用 Codemagic 云构建，配置见根目录的 `codemagic.yaml`，产物是未签名的 IPA，可以用 Sideloadly / AltStore 签名安装
- 测试：`cd app && flutter test`；PDF 相关测试需要把环境变量 `PDFIUM_PATH` 指向一个 `pdfium.dll` / `libpdfium`

## 许可

本项目代码使用 MIT 许可（见 `LICENSE`）。第三方模型、字体和库各自保留原有许可，见 `docs/licenses.md`。
