# Glacier

Glacier 是一个面向 Android 的媒体浏览与播放应用，支持本地目录、WebDAV、Emby 三类来源统一管理，提供收藏夹、标签、历史记录、图片查看和视频播放能力。

## 功能亮点

- 多来源聚合：本地 / WebDAV / Emby
- 收藏夹控制台：统一管理媒体入口
- 图片浏览：标签筛选、搜索、排序
- 视频播放：目录浮层、播放列表快速切换
- 标签系统：资源组织与检索
- 历史记录：快速回看最近浏览内容

## 功能预览

<p>
  <img src="assets/feature/01_dashboard.jpg" width="240" alt="收藏夹控制台" />
  <img src="assets/feature/02_menu.jpg" width="240" alt="收藏夹快捷菜单" />
  <img src="assets/feature/03_browser.jpg" width="240" alt="目录浏览" />
</p>

<p>
  <img src="assets/feature/04_video_playlist.jpg" width="240" alt="视频播放目录浮层" />
  <img src="assets/feature/05_playlist_panel.jpg" width="240" alt="播放列表浮层" />
  <img src="assets/feature/06_image_viewer.jpg" width="240" alt="图片查看器" />
</p>

## 技术栈

- Flutter
- media_kit / media_kit_video
- shared_preferences
- file_picker
- path_provider
- video_thumbnail

## 快速开始

### 1. 安装依赖

```bash
flutter pub get
```

### 2. 运行（Android）

```bash
flutter run -d android
```

### 3. 打包发布

```bash
flutter build apk --release
```

APK 输出路径：

`build/app/outputs/flutter-apk/app-release.apk`

## 项目结构

- `lib/main.dart`：应用入口
- `lib/pages.dart`：收藏夹与目录主流程
- `lib/video.dart`：视频播放器
- `lib/image.dart`：图片查看器
- `lib/webdav.dart`：WebDAV 模块
- `lib/emby.dart`：Emby 模块
- `lib/tag.dart`：标签模块
- `assets/feature/`：README 预览图资源
