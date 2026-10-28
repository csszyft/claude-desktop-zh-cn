# Claude Desktop 中文补丁

让 Windows 版 Claude Desktop 显示中文，同时保留 Cowork 工作区。当前使用“本地汉化缓存 + 恢复官方程序文件”的方案，不让修改后的 EXE 长期留在安装目录。

**当前验证范围：Windows 11、Claude 4.29.0.0 x64、第三方 API 模式、简体中文。** 这是实验性的分步工具，不是三平台通用的一键安装包。其它版本和语言尚未验证。

## 下载与安装

只从本仓库获取代码：

```powershell
git clone https://github.com/csszyft/claude-desktop-zh-cn.git
cd claude-desktop-zh-cn
```

也可以[下载本仓库 main 分支源码](https://github.com/csszyft/claude-desktop-zh-cn/archive/refs/heads/main.zip)，解压后在项目目录打开 PowerShell。这个链接是源码，不是打包好的安装器。

然后按 [Windows 4.29 安装指南](docs/windows-overlay.md) 完成三个阶段：

1. **准备副本**：复制当前版本原始文件，在仓库外生成汉化资源和安装计划，不修改已安装的 Claude。
2. **写入缓存**：临时使用引导文件，让本地界面缓存汉化资源，等待本次安装的 `READY` 标记。
3. **恢复官方文件**：还原签名有效的 EXE 和原始 ASAR，再重新打开 Claude，验证中文和 Cowork。

需要 Windows PowerShell 5.1、Python 3.10+、约 3 GB 空间，写入阶段需要管理员授权。先退出 Claude 并等更新完成；不要在包版本切换期间安装。

**不要运行旧的 `install-windows.bat`。** 直接改写 4.29 的 EXE 会使官方签名失效，Cowork 可能报 `RPC pipe closed`。缓存写入阶段也会短暂处于这个状态，必须完成恢复步骤。仓库保留的其它平台脚本是继承代码，不是本分支提供的安装方法。

## 改了什么

- 汉化资源放在本地静态缓存中；安装完成后，EXE 和两个 ASAR 恢复为官方原文件。
- 合并当前版本英文词库与中文译文，保留没有译文的新字段，并补充菜单和模型说明。
- 缓存只处理清单中的本地 JS 和词库，不缓存 API、模型请求、聊天记录或远程页面。
- 安装前校验包版本和文件哈希，备份原文件；临时写入权限在结束时恢复，不修改全局更新策略。

为什么需要换方案、哪些步骤做过验证，见 [改动记录](CHANGELOG.md)。本机用户已确认汉化和 Cowork 均可用，参数化安装工具仍需更多机器验证。

## 更新与恢复

Claude 更新后，页面构建标识不匹配时会回退到原始资源。这不是自动适配新版；清理应用缓存也可能让汉化消失。

安装中断、缓存失败或需要卸载时，请按安装指南中的[恢复与卸载说明](docs/windows-overlay.md#更新缓存和卸载)处理。不要重装工作区，也不要删除会话目录、虚拟磁盘或整个用户目录。

## 反馈问题

请到 [csszyft/claude-desktop-zh-cn Issues](https://github.com/csszyft/claude-desktop-zh-cn/issues) 提交，说明 Claude 版本、安装阶段、报错和复现步骤。附截图或日志片段前，请遮住账号、令牌、网关地址和任务内容；不用上传整个配置目录。

## 开发验证

测试使用合成资源和临时目录，不安装补丁、不启动 Claude。需要 Python 3.10+、Node.js，以及运行 Windows 测试的 PowerShell。

```powershell
python -I -m unittest discover -s tests -v
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-I18nCatalogs.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-AsarFrontendWorkflow.ps1
```

## 来源与许可

本项目 fork 自 [javaht/claude-desktop-zh-cn](https://github.com/javaht/claude-desktop-zh-cn)，基于上游 1.4.19 的词库和补丁逻辑继续修改。原作者及贡献者的署名保留，遵循 [MIT License](LICENSE)。这是非官方社区项目，与 Anthropic 无隶属关系。
