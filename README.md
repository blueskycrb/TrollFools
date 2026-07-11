# TrollFools 中文增强版

TrollFools 是一款运行在 **TrollStore（巨魔商店）环境**下的 iOS 应用插件注入工具，可以直接向已经安装的 App 注入动态库或插件资源。

本仓库是在原作者 **Lessica** 的开源项目 [Lessica/TrollFools](https://github.com/Lessica/TrollFools) 基础上进行的功能增强和问题修复版本。

> 本项目的核心注入能力、基础界面与主要架构均来源于原版 TrollFools。感谢原作者 Lessica 以及所有上游项目贡献者的开源工作。

## 主要功能

### 插件注入

- 支持向符合条件的已安装 App 注入插件。
- 支持 `.dylib`、`.deb`、`.zip`、`.framework` 和 `.bundle` 等格式。
- 支持手动选择插件并注入指定 App。
- 支持查看已经注入的插件并执行移除操作。
- 支持多种注入目标策略以及兼容性回退选项。

### App 更新后自动恢复插件

- TrollFools 会保存目标 App 已启用的插件记录。
- 当目标 App 更新、安装包被替换后，可自动重新注入原来启用的插件。
- 如果 App 更新时 TrollFools 没有运行，将在下次打开 TrollFools 后检查并恢复。
- iOS 不允许普通应用永久在后台运行，因此完全关闭 TrollFools 后，仍需再次打开它才能执行扫描和恢复。

### 本地 AutoInject 文件夹

自动注入目录位于：

```text
iCloud Drive
└── TrollFools
    └── AutoInject
```

每个目标 App 使用独立目录：

```text
AutoInject
└── 应用名称
    ├── _BundleIdentifier.txt
    ├── _TargetApp.txt
    └── 插件.dylib
```

把插件放入对应 App 的目录后，返回 TrollFools 并保持前台数秒，程序会自动扫描并处理新增或替换的插件。

### 文件夹创建方式

- **单个创建**：进入目标 App 的“高级选项”，点击“创建本地自动注入文件夹”。
- **批量创建**：在 TrollFools 首页点击“批量创建所有应用文件夹”，一次性为所有已安装的第三方 App 创建目录。
- 目录优先使用应用名称，避免只显示难以识别的 Bundle ID。
- 已创建的目标目录会被保留，即使目录中暂时没有插件也不会被自动删除。

### 其他调整

- 修复 CoreTrust 辅助工具 `ct_bypass` 无法执行的问题。
- 改善辅助命令启动失败时的错误日志。
- 修复 AutoInject 目录重复生成、创建后消失及扫描路径不一致的问题。
- 移除首页广告内容。

## 使用方法

1. 使用 TrollStore 安装 Release 页面提供的 `.ipa` 文件。
2. 打开 TrollFools。
3. 在首页批量创建目录，或者进入单个 App 的高级选项创建目录。
4. 打开系统“文件”App，进入 `iCloud Drive/TrollFools/AutoInject`。
5. 将插件复制到对应 App 名称的文件夹中，不要直接放在 `AutoInject` 根目录。
6. 返回 TrollFools，并保持应用处于前台约 8 秒。
7. 在 TrollFools 中查看处理结果；需要时可查看日志或目录中的 `_LastResult.txt`。

## 支持范围

延续原版 TrollFools 的支持范围，主要面向 TrollStore 支持的 iOS 版本及设备环境，包括：

- 可移除的系统 App。
- 通过 TrollStore 安装的已解密 App。
- 部分 App Store App 与裸动态库插件。

实际兼容性会受到 iOS 版本、目标 App 架构、插件依赖、签名方式和插件自身实现影响。

## 构建

项目使用 Xcode、Theos 和 GitHub Actions 构建。

```bash
make package
```

构建完成后会生成 `.tipa`；发布版本会转换为可直接安装的标准 `.ipa` 文件。

## 项目来源与致谢

本增强版本来源于：

- 原始项目：[Lessica/TrollFools](https://github.com/Lessica/TrollFools)
- 原作者：[Lessica](https://github.com/Lessica)

衷心感谢原作者公开 TrollFools 的源代码。没有原作者对注入流程、SwiftUI 界面、签名工具集成和项目架构的工作，就不会有本增强版本。

同时感谢原项目引用和使用的开源项目及其作者：

- [Patched-TS-App](https://github.com/34306/Patched-TS-App) — Huy Nguyen 与 Nathan
- [ChOma](https://github.com/opa334/ChOma) — opa334 与 alfiecg24
- [MachOKit](https://github.com/p-x9/MachOKit) — p-x9
- [insert_dylib](https://github.com/tyilo/insert_dylib) — tyilo
- [TrollStore](https://github.com/opa334/TrollStore) — opa334 及项目贡献者

请尊重原作者及所有上游项目的许可证、署名与开源贡献。

## 免责声明

本项目仅用于个人设备上的开发、测试和研究。请只对自己拥有或已获得授权的 App 和插件进行操作。使用者应自行承担安装、注入、数据丢失、App 崩溃或兼容性问题所产生的风险。

## 许可证

本项目继续遵循仓库中的 [LICENSE](LICENSE)。修改和分发时请保留原项目的版权、许可证及致谢信息。