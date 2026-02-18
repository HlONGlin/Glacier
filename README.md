# Glacier

Glacier 是一个面向 Android 的媒体浏览与播放应用，支持本地目录、WebDAV、Emby 三类来源统一管理，提供收藏夹、标签、历史记录、图片查看和视频播放等完整能力。

## 功能亮点

- 多来源聚合：本地 / WebDAV / Emby 统一接入
- 收藏夹控制台：集中管理来源，快速进入常用媒体目录
- 图片浏览：支持标签筛选、搜索、名称排序、升降序切换
- 视频播放：支持播放列表目录、快速切换上下条目
- 标签系统：标签管理与资源组织
- 历史记录：回看最近浏览与播放内容

## 功能截图

### 1. 收藏夹控制台
![收藏夹控制台](assets/feature/01_dashboard.jpg)

### 2. 收藏夹快捷菜单（历史/设置/标签/WebDAV/Emby）
![收藏夹快捷菜单](assets/feature/02_menu.jpg)

### 3. 目录浏览（标签 + 列表 + 名称排序）
![目录浏览](assets/feature/03_browser.jpg)

### 4. 视频播放页目录浮层（播放列表）
![视频播放目录浮层](assets/feature/04_video_playlist.jpg)

### 5. 播放列表浮层（简版展示）
![播放列表浮层](assets/feature/05_playlist_panel.jpg)

### 6. 图片查看器
![图片查看器](assets/feature/06_image_viewer.jpg)

## 技术栈

- Flutter
- media_kit / media_kit_video
- shared_preferences
- file_picker
- path_provider
- video_thumbnail

## 快速开始

### 1. 环境要求

- Flutter 3.38+
- Dart 3.10+
- Android SDK（建议 API 34+）

### 2. 安装依赖

```bash
flutter pub get
```

### 3. 开发运行

```bash
flutter run -d android
```

### 4. 打包发布

```bash
flutter build apk --release
```

产物路径：

`build/app/outputs/flutter-apk/app-release.apk`

## 项目结构（核心）

- `lib/main.dart`：应用入口
- `lib/pages.dart`：收藏夹与目录主流程
- `lib/video.dart`：视频播放器
- `lib/image.dart`：图片查看器
- `lib/webdav.dart`：WebDAV 接入与浏览
- `lib/emby.dart`：Emby 账号与接口封装
- `lib/tag.dart`：标签系统
- `assets/feature/`：README 功能截图资源（ASCII 路径）

## 说明

- 当前项目主要面向 Android 体验优化。
- 如需接入更多平台（Windows/Web），可在 Flutter 配置后扩展对应构建流程。
