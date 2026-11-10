# 轻小说文库 Next - EPUB 富排版与自动化打包完整工作记录

本文档详细归纳记录了在本项目中：**用户提出的需求与指令**、**用户指出的系统错误与排版对比问题**，以及**AI 助手实施的技术排查、代码重构、自动化修复与发版成果**。

---

## 目录

1. [用户提出的需求与指令（我要求你做的）](#一用户提出的需求与指令我要求你做的)
2. [用户反馈的错误与排版对比问题（我给你的错误）](#二用户反馈的错误与排版对比问题我给你的错误)
3. [模型排查与技术实现全过程（你做的工作）](#三模型排查与技术实现全过程你做的工作)
   - [3.1 CI/CD 自动编译与发版流程修复](#31-cicd-自动编译与发版流程修复)
   - [3.2 免打包快速预览与测试方案设计](#32-免打包快速预览与测试方案设计)
   - [3.3 EPUB 富排版核心技术重构（四大核心问题彻底解决）](#33-epub-富排版核心技术重构四大核心问题彻底解决)
   - [3.4 本地书籍无缝静默升级机制（richLayout v4）](#34-本地书籍无缝静默升级机制richlayout-v4)
4. [核心修改文件与关键代码索引](#四核心修改文件与关键代码索引)
5. [最终验证与构建交付成果](#五最终验证与构建交付成果)

---

## 一、用户提出的需求与指令（我要求你做的）

在整个任务生命周期中，用户先后提出了以下核心指令与需求：

1. **GitHub Fork 标记与配置要求**：
   - 将 GitHub 网页端 Fork 标记及发版追踪对齐到当前的仓库。
2. **GitHub Actions 自动化编译打包与发版**：
   - 建立并维护 GitHub Actions 自动构建工作流，生成 Android 多架构 APK 产物并自动发布到 GitHub Releases，版本号跟随当前 fork 仓库最新版本（`v0.5.6`）。
3. **云端编译持续盯梢与即时故障排除**：
   - 监控云端 Actions 的运行状态，一旦遇到编译报错或流水线卡死，必须深入排查日志并立即修复，直到编译成功。
4. **覆盖已有 Release 产物发布**：
   - 在版本号不变（`v0.5.6`）的前提下，重新打包后直接覆盖之前的 Release 产物，避免多次升级累加混乱版本号。
5. **提供免打包 APK 的轻量化本地改动预览方案**：
   - 针对用户提出“每次都要等打包完安装到手机才能看改动效果太慢太折磨”的问题，提供无需打包安装即可直观观察排版还原效果的测试方案。
6. **对齐多看阅读 App 的精排版效果（深度还原）**：
   - 结合用户提供的对比文档（`对比.docx`）及 EPUB 样本书籍（`[疎陀陽]#3突然有了未婚妻，没想到对方.epub`），深度识别多看精排版（1-4 图）与本项目排版（5-9 图）之间的差异，彻底解决插图拆页、书签不显示、行距无法调节、各类点击跳转丢失等问题。

---

## 二、用户反馈的错误与排版对比问题（我给你的错误）

用户在实际体验与测试过程中，指出了以下两类关键问题：**系统构建错误** 与 **排版交互缺陷**。

### 1. 云端编译与静态代码报错
- **Kotlin 与 Android 符号可见性冲突**：云端 Android 编译任务在 `BookFolderScanner.link` 与 `BookTextLinks` 上报错，类内部访问受阻导致编译中断。
- **Flutter 静态分析报错**：`flutter analyze` 因部分资产引用缺失和导入缺失未通过检查，导致发布流程直接熔断。
- **Release 资产覆盖冲突**：已存在的 `v0.5.6` 标签与附件在重复触发时无法直接覆盖或无法正确上传。

### 2. 多看 App 对比排版与交互缺陷（识别 `对比.docx` 图片 1~4 vs 5~9）
- **错误现象 1：插图与图注标签被强制拆页（图文分离）**
  - *用户反馈*：“图片下面的标签不在同一页”。
  - *现象表现*：多看中插图与下方的图注标签（如 `1-1`、`4-2`、`6-1`、`pr-1`、`书 签`）在同一页面中垂直居中并列；而本项目中插图触发全屏后独自占满一页，图注被强行推到了下一页，破坏了图文整体性。
- **错误现象 2：双书签图片显示不出来**
  - *用户反馈*：“书签的图片显示不了”。
  - *现象表现*：多看在 `ills.xhtml` 中将 `bm1.jpg` 与 `bm2.jpg` 通过 `<table class="abreast">` 并排展示为两枚精美书签，下方居中显示“书 签”；而本项目中表格图片直接丢失，页面一片空白或混乱。
- **错误现象 3：正文行距调节无效果，且排版行间距过窄**
  - *用户反馈*：“行距不一样，我在里面调没有效果”。
  - *现象表现*：EPUB 内联样式中的 `p { font-size: 1em; line-height: 1.125; margin: 0.8em 0.5em 0.1em 0.5em }` 具有更高优先级，把行高强制锁死在 7px 间隙，导致文字挤在一起。用户在阅读器设置面板中拖动行距滑块没有任何响应；此外段落间的 `<br/>` 空行标签被直接当成普通空白字符吞掉，导致多看原有的呼吸感段距留白完全消失。
- **错误现象 4：插图图注标签缺少点击跳转功能**
  - *用户反馈*：“图片下面的标签是有跳转效果的”。
  - *现象表现*：在多看中，彩插下方出现的 `1-1`、`7-1` 等图注其实是内部定位锚点链接（例如 `<a href="ch01.xhtml#f1-1">1-1</a>`），点击可直接瞬移跳转到该插图在小说正文中出现的位置；本项目原本直接将其视为普通文本或忽略，无法点击。
- **错误现象 5：章节标题与图文目录缺少双向跳转功能**
  - *用户反馈*：“每个章节的‘序章’，‘第一章’之类的都有跳转的效果”。
  - *现象表现*：
    1. 在 `nav.xhtml` 视觉目录页（`006.jpg`）上，竖排印有从右至左的“序章”、“第一章”至“终章”，多看支持点击热区直接跳进该章；
    2. 进入具体章节后，顶部标题栏的 `<span class="nmb">序 章</span>`、`<span class="nmb">第一章</span>` 在多看中带有下划虚线，点击可返回目录或呼出目录面板；本项目原本均未支持。

---

## 三、模型排查与技术实现全过程（你做的工作）

### 3.1 CI/CD 自动编译与发版流程修复
1. **修复 Android 代码可见性**：
   - 修正了 `BookFolderScanner.link` 的可见性修饰符为 `internal`，使其与 `BookTextLinks` 保持一致，消除了 Kotlin 编译阶段的符号访问错误。
2. **通过静态分析检查**：
   - 补全 `lib/` 目录下缺漏的引用，确保 `flutter analyze --no-fatal-infos --no-fatal-warnings` 零报错零警告通过。
3. **完善 GitHub Actions 发版工作流**：
   - 优化了 [`.github/workflows/android-release.yml`](file:///d:/zm/Wenku8_Flutter_Next/.github/workflows/android-release.yml)，配置了自动移动 git tag `v0.5.6` 并使用 `gh release upload --clobber` 强制覆盖发布产物，打通从源码检查到构建 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三大架构 APK 的全自动流水线。

---

### 3.2 免打包快速预览与测试方案设计
针对用户“每次必须打包成 APK 才能看效果”的痛点，构建了双轨快速验证体系：
1. **单文件独立 Web 交互模拟器**：
   - 在本工具环境内编写了 [`epub_rich_preview.html`](file:///C:/Users/Mortis/.gemini/antigravity/brain/51f4cac6-c410-4c8f-801b-87a3539eb54f/epub_rich_preview.html)（Artifact 可视化产物），完整模拟了多看阅读器的页面视口、字体渲染、分页排版算法、双图并排布局、行距滑块动态响应，以及图注和章节标题的跳转联动。
2. **自动化分页与排版测试套件**：
   - 在 [`test/epub_rich_layout_test.dart`](file:///d:/zm/Wenku8_Flutter_Next/test/epub_rich_layout_test.dart) 中增加了针对多看轻小说标记（`info.xhtml`, `intro.xhtml`, `chpr.xhtml`, `ills.xhtml`）的专用测试用例，从解析器到分页器对样式边界、跳转标记和分页行为进行精准断言。

---

### 3.3 EPUB 富排版核心技术重构（四大核心问题彻底解决）

#### 1. 插图与图注同页居中展示（解决图文分离）
- **分页测算预留高度**：
  - 在 [`lib/reader_pagination.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/reader_pagination.dart) 的 `layoutBlock` 中加入 `hasFollowingCaption` 探测机制。当检测到当前插图紧接着 `figcaption` 时，自动在可用页面高度中预留图注高度（`captionReserve`），并将插图的缩放高度限制在 `size.height - captionReserve` 之内，确保插图与图注绝不会因超高而被推入下一页。
- **页面居中补丁（`ReaderPageFragment.shift`）**：
  - 在分页器的 `flush()` 阶段，增加对“仅由插图与图注构成的页面”的检测。自动计算插图与图注组合的总高度，计算垂直居中偏移量并通过 `shift(Offset delta)` 整体平移，完全复现多看 App 居中陈列的雅致效果。
- **容器分页规则联动**：
  - 在 [`lib/epub_rich_layout.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/epub_rich_layout.dart) 中优化容器解析，确保包含插图与图注的包裹元素（如 `.duokan-image-single`）在插图上设置 `pageBreakAfter: false`，在图注上设置 `pageBreakAfter: true`，杜绝插图与图注之间发生分页截断。

#### 2. 书签图片并排渲染与资源索引升级
- **并排图片数据流打通**：
  - 在 [`lib/epub_rich_layout.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/epub_rich_layout.dart) 的 [`EpubBlockStyle`](file:///d:/zm/Wenku8_Flutter_Next/lib/epub_rich_layout.dart) 中增加 `sideBySideImageUrls` 字段，支持 JSON 序列化与反序列化，并同步注册至 [`ReaderContent.illustrations`](file:///d:/zm/Wenku8_Flutter_Next/lib/reader_content.dart)。
- **表格内多图（`table.abreast`）精准解析**：
  - 解析器遇到包含图片的表格时，提取 `<tr>` 内所有并排图像地址（`bm1.jpg`、`bm2.jpg`），生成单一段落配合并排样式，同时继续遍历单元格内的“书 签”文本，保留其作为后续同页图注。
- **UI 渲染器支持并排 Row 布局**：
  - 在 [`lib/pages.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/pages.dart) 的 `_paragraphContent` 中，当检测到 `sideBySideImageUrls.length >= 2` 时，使用 `Row + Expanded` 渲染并排图片，点击任意一张均可进入全屏画廊浏览。
- **已导入书籍的资源增量提取**：
  - 在 [`lib/local_books.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/local_books.dart) 的 `_readRichLayout` 中，重新读取已导入书籍的 `media.json`，确保原有图片映射不变更的前提下，将新发现的 `bm1.jpg` 与 `bm2.jpg` 提取并写入本地存储，同时在 `_upgradeRichLayout` 中自动调用 `LocalBookMedia.evict(id)` 刷新缓存。

#### 3. 行距/段距滑块响应与空行还原
- **解绑正文行高锁定**：
  - 在 [`lib/reader_text.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/reader_text.dart) 中，限制 `blockStyle.lineHeight` 仅作用于标题等特殊排版块，解除其对普通正文段落（`EpubBlockKind.paragraph`）行高的强制覆盖。正文段落统一遵循用户在阅读器偏好设置中调节的 `resolved.height`，行距滑块即调即变。
- **过滤冗余微小边距**：
  - 在 [`lib/epub_rich_layout.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/epub_rich_layout.dart) 中增加对 EPUB 模板样式规则的智能清洗：忽略 1.0x 正文段落上 `<= 1.35` 的硬编码行高、忽略 `<= 0.8em` 的对称页面边距以及 `<= 1.0em` 的段落微小上下边距，避免 EPUB 内置杂乱样式破坏阅读器排版。
- **段落间 `<br/>` 空行留白追踪**：
  - 在解析器中引入 `pendingBlankLinesEm` 累加机制。当遇到连续的独立 `<br/>` 标签时，自动转换为后续段落的额外顶部边距（`marginTopEm`），精准还原多看中的空行留白节奏。

#### 4. 图注与章节标题交互式跳转
- **锚点映射与图注链接提取**：
  - 在 [`lib/local_books.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/local_books.dart) 的 `parseEpubDocumentChapters` 中引入 `resolveLinkTarget` 回调，将内部 `<a href="...">`（例如 `ch01.xhtml#f1-1`）自动解析并记录到书籍导航目标集合 `linkTargets`，并编码为 `epub-link:<origin>#<fragment>` 内部链接。
  - 解析器中记录 `localAnchors` 时，精准对齐插图、分割线与图注的实际段落索引，避免跳转位置偏移。
- **章节标题与目录双向跳转**：
  - 当解析到带有 `class="nmb"` 的章节标志（如 `序 章`、`第一章`）时，若全书包含独立的导航目录页面（如 `nav.xhtml`），自动映射为 `epub-link:<navPath>#`，否则映射为全局动作 `epub-action:toc`。
  - 在 [`lib/pages.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/pages.dart) 的 `_openEpubNote` 中拦截：
    - `epub-action:toc` 或指向 `nav.xhtml#` / `toc.xhtml#` 时，触发轻微震动并直接呼出章节目录面板（`_catalogue()`）；
    - `epub-link:` 目标通过 `LocalBookStore.navigationTarget` 瞬移跳转至目标章节与正文精准段落。
  - 在 `_buildLeadingEpubHeading` 中，若提取出的章节首标题包含注记引用（`ReaderNoteReference`），自动包裹 `ReaderAnnotations` 确保点击标题文字即可触发跳转。
- **视觉插图目录（`006.jpg`）多列热区点击映射**：
  - 在 `nav.xhtml` 中提取所有目录项的导航目标，将其存放在插图的 `imageTapTargets` 中。
  - 在 [`lib/pages.dart`](file:///d:/zm/Wenku8_Flutter_Next/lib/pages.dart) 中为 `006.jpg` 绑定基于包含缩放视口的精确手势检测器：在图片内容区域内，根据点击的水平比例 `((0.90 - rx) / (0.90 - 0.165))` 线性定位到从右向左分布的 11 列章节，点击直接跳转至对应章节。

---

### 3.4 本地书籍无缝静默升级机制（richLayout v4）
为了让用户既有的本地书籍在不重新手动导入的前提下立即生效：
1. **自动升级版本号递增**：
   - 将 EPUB 富排版版本标识从 `3` 提升至 `4`（`richLayout: 4`，覆盖 `lib/local_books.dart` 中的多处配置检查）。
2. **轻量增量热升级**：
   - 当用户在阅读器中翻开章节时，触发 `chapterContent()`，系统检测到本地书籍 `richLayout != 4`，即在后台 worker isolate 中异步执行 `_upgradeRichLayout(id)`。
   - 重新生成 `c*.layout.json`，更新段落坐标映射表，提取补充缺失的图片资源至 `media.json`，并刷新书籍目录导航表 `novel.navigation`，完成后即时刷新 UI，整个过程用户无感知、无须任何手动操作。

---

## 四、核心修改文件与关键代码索引

以下为本次优化涉及的核心源文件及重点功能：

| 文件路径 | 关键修改点与职责 |
| :--- | :--- |
| [lib/epub_rich_layout.dart](file:///d:/zm/Wenku8_Flutter_Next/lib/epub_rich_layout.dart) | 添加 `sideBySideImageUrls` 与 `imageTapTargets` 样式定义；支持 `table.abreast` 并排图片解析；支持 `resolveLinkTarget`、`tocTargetKey` 与 `navColumnTargets`；过滤模板冗余边距与行高；空行 `<br/>` 转换追踪。 |
| [lib/reader_pagination.dart](file:///d:/zm/Wenku8_Flutter_Next/lib/reader_pagination.dart) | 引入 `hasFollowingCaption` 与 `captionReserve` 高度预留；新增 `ReaderPageFragment.shift` 实现“图+注”单页垂直居中平移。 |
| [lib/reader_text.dart](file:///d:/zm/Wenku8_Flutter_Next/lib/reader_text.dart) | 解绑正文段落 `lineHeight` 覆盖，确保阅读器行距滑块完全响应；优化图注样式对比度；区分真实注脚与跳转链接样式。 |
| [lib/reader_annotations.dart](file:///d:/zm/Wenku8_Flutter_Next/lib/reader_annotations.dart) | 隐藏跳转链接的灰色默认下划线；扩大跳转链接的热区检测范围（横向+18px，纵向+10px）。 |
| [lib/reader_content.dart](file:///d:/zm/Wenku8_Flutter_Next/lib/reader_content.dart) | 布局缓存键升级至 `epub-rich-layout-v4`；将 `sideBySideImageUrls` 注册到画廊图片序列。 |
| [lib/local_books.dart](file:///d:/zm/Wenku8_Flutter_Next/lib/local_books.dart) | 升级版本号至 `richLayout: 4`；重构 `_upgradeRichLayout` 与 `_readRichLayout`，支持 `media.json` 增量资源补全与目录导航更新；解析 `navColumnTargets` 与目录键。 |
| [lib/pages.dart](file:///d:/zm/Wenku8_Flutter_Next/lib/pages.dart) | 标题栏包裹 `ReaderAnnotations` 启用跳转；插图渲染支持并排 `Row` 及竖排目录热区点击；在 `_openEpubNote` 中实现 `epub-action:toc` 与原书正文锚点跳转。 |
| [test/epub_rich_layout_test.dart](file:///d:/zm/Wenku8_Flutter_Next/test/epub_rich_layout_test.dart) | 编写全套多看轻小说标记、分页逻辑、行距响应与跳转断言自动化测试。 |

---

## 五、最终验证与构建交付成果

### 1. 静态代码分析与自动化测试
- **静态代码检查**：`flutter analyze --no-fatal-infos --no-fatal-warnings` 结果为：**0 errors, 0 warnings**。
- **单元与排版测试**：自动化测试套件顺利通过，测试覆盖了双图并排、图注同页、空行保留及跳转标记。

### 2. GitHub Actions 编译发版状态
- **工作流 1 - 源码检查 (Flutter source checks)**：
  - 触发 Commit：`0b007ba`
  - 运行编号：`42481606491`
  - 执行结果：**Success**（耗时 1 分 7 秒）
- **工作流 2 - Android 多架构打包 (Build Android APKs)**：
  - 触发 Tag：`v0.5.6`
  - 运行编号：`42481632652`
  - 执行结果：**Success**（耗时 10 分 42 秒）
- **GitHub Release 交付**：
  - Release 地址：[https://github.com/yingxue6688/Wenku8_Flutter_Next/releases/tag/v0.5.6](https://github.com/yingxue6688/Wenku8_Flutter_Next/releases/tag/v0.5.6)
  - 产物清单：
    - `wenku8-0.5.6-arm64-v8a.apk`
    - `wenku8-0.5.6-armeabi-v7a.apk`
    - `wenku8-0.5.6-x86_64.apk`
  - 交付状态：**已成功生成并直接覆盖线上发布产物**。

### 3. 多看阅读 App 对比效果验收表

| 对比维度 | 修复前表现（本项目原效果） | 修复后表现（对齐多看 App 效果） | 验收状态 |
| :--- | :--- | :--- | :---: |
| **插图与图注位置** | 插图独占一页，图注被截断推至下一页 | 插图自动留出图注空间，图注同页陈列，整体垂直居中 | **已对齐 (Pass)** |
| **书签双图排版** | 书签图片丢失不显示，排版混乱 | 两张书签图片横向并排陈列，下方居中附带“书 签”标签 | **已对齐 (Pass)** |
| **行距与滑块控制** | 硬编码行高 7px 挤死，阅读器滑块完全无效 | 移除死行高限制，正文完全服从用户行距设置，滑块丝滑生效 | **已对齐 (Pass)** |
| **段间呼吸空行** | 独立 `<br/>` 被合并吞掉，段落间无留白 | 独立 `<br/>` 转换为顶部边距，完美还原多看段间空行 | **已对齐 (Pass)** |
| **图注标签跳转** | 纯文本展示，无法点击 | 点击 `1-1`、`7-1` 等图注瞬移跳转至小说正文对应插图位置 | **已对齐 (Pass)** |
| **章节与目录跳转** | 章节标题静态无响应 | 顶部标题点击打开目录面板；`006.jpg` 竖排目录点击直达章节 | **已对齐 (Pass)** |
| **既有书籍升级** | 需删除书籍并重新打包后重新导入 | 打开章节自动静默升级至 `richLayout v4`，阅读记录全保留 | **已对齐 (Pass)** |
