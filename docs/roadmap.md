# 自用扫描 App（Android）路线图

参考对象：CamScanner 桌面版 1.91.0。拆包分析见对话记录，原版代码和闭源模块（`@ccint/pageScan` 等）一律不使用，全部基于开源组件自己实现。

## 范围

- 平台：先出 Android APK，之后用同一套代码出 iOS IPA。暂不做桌面版。iOS 怎么编译和签名以后再定（需要 macOS，或用 GitHub Actions 的 macOS 机器）。
- 图像来源：手机摄像头取景拍摄；导入相册图片、本地 PDF 和图片文件。
- 不做：大模型类 AI 功能（翻译、总结、AI 对话、AI PPT、AI 脱敏、Agent）、登录、云同步、支付、企业版、分享链接、有法律效力的电子签、Apex 1 Pro 扫描仪硬件。AI 功能以后可以在独立模块里加上。
- 完全离线运行，文档不出手机。端上推理模型（OCR、版面分析、补全）不算上面说的 AI 功能，照常使用。

## 技术选型

| 方面 | 选择 | 理由 |
|---|---|---|
| 语言/界面 | Flutter（Dart） | 一套代码出 Android 和 iOS，界面两端一致 |
| 相机 | `camera` 插件（Android 用 CameraX，iOS 用 AVFoundation） | 官方维护，支持预览帧流和拍照 |
| 图像处理 | `opencv_dart`（OpenCV 4.x 的 FFI 绑定） | 两端同一套 Dart 代码调用 OpenCV |
| 端上模型推理 | ONNX Runtime（Flutter 插件，Android/iOS 均有官方运行库） | OCR、版面、表格、展平、补全统一用一个运行时 |
| OCR | PaddleOCR PP-OCRv5 mobile（ONNX，RapidOCR 的转换版本） | 中文识别率好，不依赖 Google 或 Apple 的系统服务 |
| PDF 渲染和文本 | `pdfrx`（PDFium） | 两端都能用，许可证宽松 |
| PDF 生成和编辑 | PDFium 编辑接口（FFI）为主，简单生成用 `pdf` 包 | 合并、删页、旋转、插图、注释、保存 |
| 数据库 | `drift`（SQLite + FTS5 全文索引） | 元数据和 OCR 文本搜索，两端一致 |
| 二维码 | `mobile_scanner` 或 ZXing | 待 P3 时比较 |
| 重计算 | 放到后台 isolate 执行 | 不卡界面 |

不使用 ML Kit Document Scanner 和 Apple VisionKit：前者依赖 Google Play 服务，很多国内手机上用不了；两者都只覆盖一个平台，效果也不一致。

许可证原则：只用 MIT、BSD、Apache-2.0 这类宽松许可的库和模型，不用 GPL、AGPL（例如 MuPDF）。这样以后开源、上架、换平台都没有限制。每加一个依赖或模型都在 `docs/licenses.md` 记一笔。

## 数据模型

- `Document`：id、标题、所属文件夹、标签、创建和修改时间、是否删除（回收站）、是否加锁。
- `Page`：所属文档、顺序、原图路径、四个角点、滤镜参数、处理后图片路径、OCR 文本、OCR 结果 JSON（文字框坐标）。
- 原图一直保留，裁剪和滤镜都只是参数，随时可以重新调整。
- 导出的 PDF 和图片放在应用目录，通过系统分享面板发出去。

## 分阶段计划

每个阶段做完都能装到手机上用。

进度：P0–P6 已完成并在真机（vivo）上验证（P6 只做了转 Word、转 Excel）。P7 起未开始。

### P0 工程骨架
- Flutter 工程、路由、drift 数据库、文件存储目录结构
- 首页文档列表、空状态、权限申请（相机、相册）
- OpenCV、ONNX Runtime、PDFium 依赖接入，并验证能在真机上跑通
- 代码分层：`core/`（纯 Dart 算法和数据，不碰平台）和 `platform/`（少量平台相关代码），方便 iOS 直接复用

### P1 扫描（核心）
- 相机页：单张、批量连拍，取景时实时显示检测到的边框；画面稳定时自动拍摄；闪光灯
- 从相册和文件导入图片
- 边缘检测：先用 OpenCV（灰度、模糊、Canny、轮廓、四边形拟合），效果不够再换小型检测模型
- 手动拖动四个角点，放大镜辅助对齐；透视矫正
- 滤镜：原图、增强、灰度、黑白、去阴影、锐化、省墨、提亮
- 旋转、页面排序、删除、重拍、插入新页
- 导出 PDF、JPG、长图，系统分享，PDF 纸张大小和边距设置

### P2 文件管理
- 文件夹、标签、重命名、移动、复制、批量操作
- 最近、回收站（30 天自动清理）
- 搜索：标题加 OCR 全文
- 列表、网格、大缩略图视图，排序方式
- 文档加锁（密码或指纹）

### P3 OCR
- PP-OCRv5 检测加识别，整页 OCR 和框选区域 OCR
- 识别结果编辑、复制、导出 TXT
- 生成可搜索 PDF（图片上叠一层不可见文字）
- OCR 文本写入全文索引
- 二维码和条码识别

实现说明：模型由 `app/tool/prepare_ocr_models.py` 改成 uint8 输入、识别模型直接输出每步最大类别，减少平台通道上传的数据量；整个流程在一个常驻的后台 isolate 里跑。扫描后默认自动在后台识别（设置里可关），裁剪或旋转后重新识别，只换滤镜保留结果。二维码用 flutter_zxing（zxing-cpp），不用 ML Kit。

### P4 PDF 阅读与编辑
- 阅读器：单页、连续滚动、缩放、缩略图导航、跳页、文本搜索
- 注释：高亮、下划线、删除线、手绘、文本框、便签，存回 PDF
- 签名：手写板绘制签名；拍照提取签名和印章（去背景、二值化、透明 PNG）；签名库；放到页面上、缩放、旋转
- 水印：文字和图片水印，可调透明度、角度、密度
- 手动脱敏：框选或按关键字查找（OCR 文本加正则匹配手机号、身份证号、银行卡号），真正删除内容，不只是盖一个黑框。扫描件直接改图片像素；文字版 PDF 用 PDFium 删除框内的文字对象，或者把这一页栅格化
- 打印：`printing` 包（Android PrintManager / iOS AirPrint）

实现说明（用户选定：只作用在 App 里的扫描文档上，不做原生 PDF 编辑器）：标注、签名、便签存成每页一层可再编辑的数据（处理后图片的像素坐标），裁剪或旋转时按透视变换换算过去；水印是文档级设置；导出时把它们画进整页图片，便签另外写成 PDF 注释。脱敏是不可撤销的：框换算回原图后，原图和处理后图片都涂黑，再重新识别文字。阅读器把文档生成带文字层的 PDF（有缓存），用 pdfrx 的 PdfViewer 显示，支持搜索、跳页、缩略图、打印。外部文字版 PDF 的原生编辑以后再定。

### P5 PDF 工具箱
- 合并、拆分、提取页、删页、旋转、重排
- 图片转 PDF、PDF 转图片
- 压缩：按质量和分辨率重新编码图片
- 加密、解密（需要知道密码）
- 只做自用合法场景：不做破解别人的 PDF 密码

实现说明：App 里的文档可以多选合并、提取页或拆分成新文档，导出 PDF 时可选图片质量和打开密码（AES-256，自己实现的 R6 加密，已用 pypdf 和 PDFium 验证）。外部 PDF 的工具箱用 pdfrx 直接重组页面（合并、拆分、提取、删除、旋转、重排、去密码），文字保持矢量；压缩是把每页重新渲染成图片，适合扫描件。给外部 PDF 直接加密码做不到（pdfrx 和 pdf 包都不能改写已有 PDF），只有 App 生成的 PDF（导出、图片转 PDF、压缩结果）能加密码。电脑上的 PDFium 测试需要环境变量 PDFIUM_PATH 指向 pdfium.dll（_tools/ocrenv 里 pypdfium2 带了一个）。

### P6 格式转换（最难，效果会比商业版差）
- PDF/扫描件转 Word：PP-Structure 版面分析（标题、段落、表格、图片区域）+ OCR，生成 docx。docx、xlsx、pptx 都是 zip 包里的 XML，用 Dart 的 `archive` 包和 XML 模板自己生成
- 转 Excel：表格结构识别模型（SLANet）+ OCR，生成 xlsx
- 转 PPT：每页一张幻灯片，图片在下层，文字可编辑
- Office 转 PDF：手机上没有好用的离线方案。先只做 docx 和图片的简单渲染，复杂的 Word、Excel、PPT 用系统里已装的 WPS 打开后另存为 PDF；需要时再考虑接入自建的 LibreOffice 服务
- 文字版 PDF（不是扫描件）直接用 PDFium 提取文字和位置，不走 OCR
- Office 转 PDF 在 iOS 上可以用系统自带的 Quick Look 渲染后打印成 PDF，Android 端没有对应能力

实现说明（用户选定：只做转 Word 和转 Excel，不做 PPT 和 Office 转 PDF）：版面分析用 PP-Structure CDLA 模型（7 MB），表格用 SLANet+（7.6 MB），都在 OCR 的后台 isolate 里跑，第一次用到才加载。Dart 后处理和 RapidLayout / RapidTable 的 Python 版逐项对过（_tools/ref_layout.py 记录模型原始输出，Dart 测试回放）。扫描文档复用已存的 OCR 结果；外部 PDF 每页按 150 dpi 渲染给版面模型，有文字层就直接取文字，没有才 OCR。docx / xlsx 用 archive 包手写 XML，生成后用 python-docx、openpyxl 打开验证过。

### P7 进阶图像功能
- 书本模式：自动找到书脊，把左右两页拆成两张；纸面弯曲展平用 UVDoc 的 ONNX 模型
- 证件模式：身份证、护照正反面拼到一页 A4
- 拼图：多张图拼成一页
- 去手写：手写区域分割模型找到手写笔迹，再用 LaMa 补全被擦掉的地方
- 去水印、局部擦除：用户涂抹要擦的区域，LaMa 补全
- 摩尔纹和超分：可选，看模型大小和速度再定

### P8 系统集成
这一阶段平台差异最大，每项都要分别写 Android 和 iOS 的原生代码。

| 功能 | Android | iOS |
|---|---|---|
| 接收其他 App 分享的图片和 PDF、注册为 PDF 打开方式 | share intent | Share Extension、文档类型声明 |
| 桌面小部件、快捷方式（一键扫描） | App Widget、App Shortcuts | WidgetKit、快捷指令 |
| 悬浮球 + 截屏 + 框选识字 | 悬浮窗权限 + MediaProjection | 做不了：iOS 不允许悬浮窗，也不允许截别的 App 的屏 |
| 选中文字后发送到本 App | PROCESS_TEXT | Action Extension |
| 自动备份（zip，可选 WebDAV） | 共用 Dart 代码 | 共用 Dart 代码 |

## 模型清单与体积估算

| 用途 | 模型 | 大约大小 |
|---|---|---|
| OCR 检测和识别 | PP-OCRv5 mobile det + rec | 15–20 MB |
| 版面分析 | PP-DocLayout 的小模型 | 10–20 MB |
| 表格结构 | SLANet | 约 10 MB |
| 纸面展平 | UVDoc | 约 30 MB |
| 补全（去手写、去水印） | LaMa（量化后） | 50–200 MB |

基础 APK（Flutter 引擎 + OpenCV + ONNX Runtime + PDFium + OCR 模型）预计 70–100 MB，只打包 arm64-v8a 架构。P6、P7 的大模型第一次使用时再从本地文件导入，不打进安装包。

## 风险

- 低端手机上，版面分析和补全模型可能要跑几秒到十几秒，需要放进后台任务并显示进度
- 转 Word、Excel 的效果比 CamScanner 云端差，复杂表格和多栏排版尤其明显
- 各模型的许可证和 ONNX 转换版本要逐个确认（PaddleOCR 是 Apache-2.0，LaMa 是 Apache-2.0，UVDoc 待确认）
- Office 转 PDF 没有理想的离线方案

## 开发环境

- 本机已有：JDK 21、Android Studio（`D:\Program Files\Android\Android Studio`）、Android SDK（`D:\Android\Sdk`，API 36/36.1，build-tools 35–37）、adb
- 需要安装：Flutter SDK；NDK 和 CMake（原生插件要用，首次构建时通过 SDK Manager 安装）
- 测试：用户有安卓真机，功能做完后通知用户连 USB 调试
- iOS：以后再定编译和签名方式
