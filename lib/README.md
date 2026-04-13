# lib 目录说明

## 目标

`lib/` 现在按“入口文件 + 领域子目录 + 基础设施目录”组织，减少主目录散落的辅助文件，方便继续按模块维护。

## 当前目录分层

### 入口与聚合文件

- `main.dart`
  应用启动入口，负责初始化 Flutter、播放器能力和全局设置。
- `app/app.dart`
  应用根组件，配置 `MaterialApp`、主题和路由。
- `pages.dart`
  收藏夹/目录浏览主页面聚合文件，仍作为页面主入口保留在根目录。
- `image.dart`
  图片查看器主入口，保留在根目录，辅助实现集中在 `image/`。
- `video.dart`
  视频播放器主入口与桌面/移动页面分发文件，播放器细分逻辑在 `player/` 与 `features/media/player/`。
- `tag.dart`
  标签系统主入口，保留在根目录，标签模型、筛选、持久化等辅助代码放到 `tag/`。
- `webdav.dart`
  WebDAV 账号与客户端主入口。
- `emby.dart`
  Emby 账号、客户端与媒体访问主入口。

### Emby 目录

- `emby/`
  Emby 模块的公共能力、专属 UI 与页面辅助实现。

主要文件：

- `emby/exclusive_ui.dart`
  Emby 专属首页与交互主入口，聚合各类辅助逻辑和 `part` 页面。
- `emby/cover_layout.dart`
  Emby 封面比例分类与布局估算工具。
- `emby/native_logic.dart`
  Emby 原生条目类型、目录/图片/视频判断逻辑。
- `emby/read_scheme.dart`
  Emby 首页与目录读取、缓存与媒体拆分协调逻辑。
- `emby/url_utils.dart`
  Emby 图片/资源 URL 的参数清理与规范化工具。
- `emby/exclusive_models.dart`
  Emby 专属 UI 使用的数据模型。
- `emby/exclusive_helpers.dart`
  Emby 标题处理、排序和公共辅助逻辑。
- `emby/exclusive_folder_helpers.dart`
  Emby 目录页 tab、库类型、排序与结构判断逻辑。
- `emby/exclusive_folder_cover_helpers.dart`
  Emby 目录封面收集与批处理辅助逻辑。
- `emby/exclusive_folder_load_helpers.dart`
  Emby 目录页预览与递归加载辅助逻辑。
- `emby/exclusive_folder_state_helpers.dart`
  Emby 目录页列表状态合并、索引与选择逻辑。
- `emby/exclusive_movie_helpers.dart`
  电影元信息和观看状态文案辅助函数。
- `emby/exclusive_series_helpers.dart`
  剧集/分季判断、进度与去重辅助逻辑。
- `emby/exclusive_state_helpers.dart`
  Emby 账号级 section 和 item 状态替换辅助。
- `emby/exclusive_*_page*.dart`
  Emby 专属目录页、电影详情页、剧集详情页 UI，作为 `exclusive_ui.dart` 的 `part` 文件。

### Sources 目录

- `sources/`
  各类来源地址与账号聚合的共享工具。

主要文件：

- `sources/accounts.dart`
  WebDAV / Emby 账号共享读取与认证信息组装。
- `sources/refs.dart`
  本地 / WebDAV / Emby 来源地址构造、识别与解析。

### UI 目录

- `ui/`
  跨模块共享的 UI 主题与组件工具。

主要文件：

- `ui/kit.dart`
  全局主题、通用提示、面板展示和基础 UI 辅助。

### Debug 目录

- `debug/`
  调试与诊断相关页面/工具。

主要文件：

- `debug/inspector.dart`
  播放代理与播放器采样的调试检查工具。
- `debug/thumbnail_inspector.dart`
  缩略图/封面生成失败原因的诊断工具。

### 基础目录

- `app/`
  应用级配置，例如路由表。
- `core/`
  基础能力，如网络、日志、设置、工具函数、特性开关。

主要文件：

- `core/network/remote_media_cache.dart`
  远程媒体分段下载与前缀缓存。
- `core/storage/secure_store.dart`
  安全存储封装，以及 Emby / WebDAV 账号密钥读写。
- `core/utils/app_settings.dart`
  应用级设置读写与通知。
- `core/utils/app_history.dart`
  播放/目录历史记录与历史上下文模型。
- `core/utils/app_shared.dart`
  对外聚合入口，并承载缩略图缓存、WebDAV 文件缓存、封面缓存与通用字符串辅助。
- `features/`
  新架构下按业务域拆分的功能代码，例如账号、播放器数据层与展示层。
- `models/`
  跨页面共享的数据模型。
- `stores/`
  轻量状态存储。

### 页面相关目录

- `pages/`
  `pages.dart` 对应的辅助实现。

主要文件：

- `pages/media_helpers.dart`
  页面层的媒体识别、排序文案、WebDAV 缩略图等辅助逻辑。
- `pages/navigation_helpers.dart`
  从标签或来源跳转到目录页的导航辅助函数。
- `pages/tag_navigation_helpers.dart`
  标签目标点击后的打开逻辑，负责把本地 / WebDAV / Emby 条目导向对应页面。
- `pages/tag_source_helpers.dart`
  标签相关 source key 解析与构造工具。
- `pages/folder_detail_host.dart`
  `FolderDetailPage` 宿主 widget，承接目录页状态类。
- `pages/folder_detail_state.dart`
  `FolderDetailPage` 主状态类实现。
- `pages/folder_*.dart`
  目录页拆分文件，分别负责控制器、模型、工具栏、渲染、加载、封面、打开动作等。
- `pages/settings_page.dart`
  设置页实现。
- `pages/history_page.dart`
  历史记录页实现。
- `pages/favorites_page.dart`
  收藏夹页实现。

### 标签目录

- `tag/`
  `tag.dart` 对应的辅助实现。

主要文件：

- `tag/tag_models.dart`
  标签实体、目标元数据、标签类型定义。
- `tag/tag_interaction_helpers.dart`
  标签编辑、筛选、弹窗和菜单等交互辅助。
- `tag/tag_manager_filters.dart`
  标签管理页的筛选、排序和目标过滤逻辑。
- `tag/tag_store_algorithms.dart`
  标签集合与目标集合的纯算法处理。
- `tag/tag_store_persistence.dart`
  标签数据读写、恢复、迁移和颜色选择。
- `tag/tag_files_tab_view.dart`
  标签文件页签 UI，作为 `tag.dart` 的 `part` 文件。
- `tag/tag_ui_sections.dart`
  标签列表与管理区 UI，作为 `tag.dart` 的 `part` 文件。

### 图片目录

- `image/`
  `image.dart` 对应的辅助实现。

主要文件：

- `image/provider_helpers.dart`
  图片 provider 缓存与本地缩略图组件。
- `image/preload_windows.dart`
  图片翻页和条带模式下的预加载窗口策略。
- `image/overlay_layout_helpers.dart`
  右键菜单、尺寸菜单等浮层布局计算。
- `image/source_resolver.dart`
  本地 / WebDAV / Emby 图片源解析。
- `image/ratio_cache.dart`
  图片宽高比缓存。
- `image/strip_sync_helpers.dart`
  图片条带模式的索引同步辅助逻辑。
- `image/strip_layout_helpers.dart`
  条带模式布局与滚动偏移计算。
- `image/viewer_render_helpers.dart`
  图片查看器远程图片渲染辅助。
- `image/tiles.dart`
  媒体缩略图和图片入口 tile，作为 `image.dart` 的 `part` 文件。
- `image/strip_item.dart`
  条带模式单项渲染，作为 `image.dart` 的 `part` 文件。

### 播放器目录

- `player/`
  `video.dart` 的 `part` 文件，按手势、控制栏、桌面/移动端播放面板等职责拆分。

主要文件：

- `player/video_settings_sync.dart`
  播放器设置加载辅助逻辑，负责桌面/移动端设置项读取与聚合。
- `player/video_history_sync.dart`
  播放历史写入、进度刷新与历史提交判定辅助逻辑。
- `player/video_source_resolution.dart`
  桌面端媒体源组装与移动端播放源解析辅助逻辑。
- `player/video_feedback_helpers.dart`
  播放器提示与错误反馈辅助逻辑。
- `player/video_subtitle_helpers.dart`
  播放器字幕来源解析、Emby 字幕 URL 构造与字幕候选刷新辅助逻辑。
- `player/video_mobile_open_flow.dart`
  移动端打开视频、续播定位、路由退出清理与切换流程辅助逻辑。
- `player/video_desktop_catalog_flow.dart`
  桌面端目录弹出、目录预热与播放列表媒体构建辅助逻辑。
- `player/video_mobile_control_actions.dart`
  移动端播放/暂停、倍速、相对跳转与控制动作辅助逻辑。
- `player/video_desktop_controls.dart`
  桌面端 UI 唤醒、标题提示与倍速弹层辅助逻辑。
- `player/video_desktop_host.dart`
  桌面端播放器宿主 widget，承接桌面播放器状态类。
- `player/video_mobile_host.dart`
  移动端播放器宿主 widget，承接移动播放器状态类。
- `player/video_desktop_state.dart`
  桌面端播放器主状态类实现。
- `player/video_mobile_state.dart`
  移动端播放器主状态类实现。

### 仍在根目录的工具/模块文件

这部分文件当前仍是根目录直放，原因是它们仍作为主入口文件或跨模块共享工具使用，后续可以继续按模块下沉：

当前根目录已基本只保留应用/模块入口文件。

## 本次整理内容

本次已完成以下归类：

- 原根目录 `pages_*` 辅助文件迁入 `pages/`
- 原根目录 `tag_*` 模型与辅助文件迁入 `tag/`
- `tag.dart` 的 `part` 文件迁入 `tag/`
- 原根目录 `image_*` 辅助文件迁入 `image/`
- `image.dart` 的 `part` 文件迁入 `image/`
- 原根目录 `emby_exclusive_*` 与 `emby_cover_layout.dart` 迁入 `emby/`
- 原根目录 `emby_native_logic.dart`、`emby_read_scheme.dart`、`emby_url_utils.dart` 迁入 `emby/`
- 原根目录 `source_accounts.dart` 与 `source_refs.dart` 迁入 `sources/`
- 原根目录 `remote_media_cache.dart` 与 `secure_store.dart` 迁入 `core/`
- 原根目录 `ui_kit.dart` 迁入 `ui/`
- 原根目录 `inspector.dart` 与 `thumbnail_inspector.dart` 迁入 `debug/`
- 原根目录 `utils.dart` 迁入 `core/utils/app_shared.dart`
- `core/utils/app_shared.dart` 已进一步拆分为 `app_settings.dart`、`app_history.dart` 和保留的共享缓存/工具实现
- 同步修正所有相关 import 与 `part` 路径

## 后续建议

如果继续减少根目录文件数，建议按以下顺序推进：

1. 视 `webdav.dart` / `emby.dart` 体量，继续拆出 `data/`, `ui/`, `models/` 级别子目录，或让 `emby.dart` 变成纯 barrel/入口文件
2. 如有需要，再把 `pages.dart`、`tag.dart`、`image.dart`、`video.dart` 进一步瘦身为更纯粹的入口文件
3. 评估 `core/utils/app_shared.dart` 剩余的 cache / storage / string helpers 是否继续细拆

这样能继续降低根目录密度，同时保持每次调整范围可控。
