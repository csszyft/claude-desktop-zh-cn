# Windows 4.29：保留汉化和 Cowork

这个分支基于 [javaht/claude-desktop-zh-cn](https://github.com/javaht/claude-desktop-zh-cn) 的 1.4.19。原项目负责词库和大部分补丁逻辑，这里补上 Windows 4.29 的菜单、词库兜底，以及 Cowork 签名冲突的处理。

## 为什么换方案

4.29 把前端放进了 `ion-dist.asar`。直接汉化这个包，需要同步修改 `Claude.exe` 内的完整性哈希。界面可以正常打开，但 EXE 的官方签名会失效。我们在本机遇到的后果是 Cowork 拒绝连接，日志反复出现：

```text
signature verification failed: client executable is not signed
RPC pipe closed
```

所以，“设置页显示中文”还不能算安装成功。

现在改为先让本地页面把译文写入 Service Worker 缓存，再恢复官方 EXE 和两个原始 ASAR。最终落盘的程序文件保持官方原样，汉化从用户目录内的静态缓存提供。没有改 Cowork 服务，没有关闭签名检查，也没有修改微软商店更新策略。

本机 Windows 11、Claude 4.29.0.0 x64、第三方 API 模式、简体中文已完成这套流程，用户确认 Cowork 恢复正常。仓库里的参数化工具由这次流程整理而来；准备阶段做过真实资源副本测试，提权写盘部分仍需更多机器验证。目前只接受这一版本和语言，不宣称兼容所有新版。

## 开始前

- 需要 Windows PowerShell 5.1、Python 3.10+。准备文件约需 3 GB 空间，实际写入需要管理员授权。
- 先退出 Claude，等已有更新完成，再检查 `Get-AppxPackage -Name Claude`。官网安装器也会部署 MSIX，路径在 `WindowsApps` 不代表从微软商店下载。
- 当前 EXE 必须有有效官方签名。如果已经装过直接写包的补丁，先恢复对应版本的原始 EXE、`app.asar` 和 `ion-dist.asar`。不要拿修改后的文件当原始备份。
- 不要重装工作区，也不要删除 `local-agent-mode-sessions`、虚拟磁盘或整个用户目录。

这仍是实验性的分步安装，不是双击后无人值守的安装包。**第二步暂时使用签名失效的 EXE，期间 Cowork 仍不可用；完成第三步才恢复。** 不愿接受这段临时状态的话，先不要使用此方案。

## 1. 只在副本中准备

在仓库目录打开普通 PowerShell。工作目录必须放在仓库外，避免把程序副本、日志和用户配置推送到 GitHub：

```powershell
$work = Join-Path $env:LOCALAPPDATA ('ClaudeZhOverlay\4.29-' + (Get-Date -Format yyyyMMdd-HHmmss))
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\prepare_windows_overlay.ps1 -Workspace $work
```

脚本复制原始文件，在副本中汉化，并生成 `seed`、`finish`、`recover` 三份计划。此阶段不修改已安装的 Claude，也不改用户设置。输出目录已存在时会停止，不覆盖上一轮材料。

## 2. 写入缓存

下面的命令会弹出 UAC。它只临时调整当前 Claude 包内五个指定路径的权限，备份后替换三个文件；退出时恢复权限并重新启动原先运行的 Cowork 服务。

```powershell
$apply = (Resolve-Path .\scripts\apply_windows_overlay.ps1).Path
$plan = Join-Path $work 'seed\plan.json'
$args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PlanPath "{1}"' -f $apply, $plan
Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $args -Wait
Get-Content (Join-Path $work 'seed\result.json')
```

只有结果中 `Success` 为 `true` 才继续。从开始菜单打开 Claude，不要发起任务。页面右下角出现 `Chinese overlay READY` 后，查看日志确认缓存就绪：

```powershell
Select-String -Path "$env:LOCALAPPDATA\Claude-3p\logs\claude.ai-web.log" -Pattern 'CLAUDE_ZH_READY:' | Select-Object -Last 1
```

每次准备都生成独立标记。第三步只接受本次标记，不会把旧日志误当成本次成功。缓存逐文件校验 SHA-256；已有其他根作用域 Service Worker 时停止，不覆盖它。

## 3. 恢复官方文件

```powershell
$plan = Join-Path $work 'finish\plan.json'
$args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PlanPath "{1}"' -f $apply, $plan
Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $args -Wait
Get-Content (Join-Path $work 'finish\result.json')
```

这一步会关闭 Claude，恢复官方三个文件，把菜单语言设为官方已有的 `zh-Hans`。其它现有配置字段保留。完成后重新从开始菜单打开 Claude，检查主界面仍是中文，并在 Cowork 中实际执行一次简单命令。只有程序启动、汉化和工作区都正常，才算验收完成。

如果缓存准备失败，或第二步后被打断，用相同命令把计划换成 `recover\plan.json`。它不要求 READY，恢复官方文件并把语言改回英文。新建的 `config.before.json` 留在本地工作目录中。恢复时只接受当前计划对应的原始或临时文件哈希；版本变了或文件被其他工具修改时会停止，不能跨版本硬恢复。

## 更新、缓存和卸载

缓存只拦截 `app://localhost` 下清单内的 JS 和 i18n JSON，不缓存 API、模型请求、聊天记录或远程页面。网页构建时间戳或入口脚本变化后回退原始资源；这是失配保护，不是自动适配新版。相同时间戳和入口文件名的厂商热修补不在检测范围内。

清理应用缓存、重置用户目录或 Chromium 后续改变 Service Worker 行为，都可能让汉化消失。Worker 脚本在第三步后不再位于官方包中；当前机器重启后可用，但长期更新检查行为仍需要观察。

不要再次运行旧版 `install-windows.bat` 给 4.29 直接写包。本 fork 已在停止 Claude、恢复旧备份之前拦下这条安装路径。旧入口的卸载只恢复磁盘文件，不能删除 Service Worker 缓存。

若要卸载缓存层，可在 Claude 正常提供的开发者工具中，切到 `app://localhost` 页面对应的 Console，运行 `resources/windows-overlay-remove.js` 的内容。它只注销本补丁命名的 Worker 和缓存，然后手动重载页面。不要为此绕过产品的开发者工具限制，也不要删除整个用户目录。官方中文菜单可按需要保留或切回 English。

## 已做的验证

最初的真实 4.29 测试保留了原有 39,482 个前端 key，检查了 4,535 个归档条目的完整性和 404 个修改后 JS 的语法。缓存方案额外调整了一处 locale 桥接调用，最终缓存 408 个文件。恢复后，用户确认中文和 Cowork 均可用。

自动测试覆盖缓存文件哈希、API 请求不被拦截、版本失配回退、词库合并和原文件恢复。测试不能替代 MSIX 真机安装；本 fork 没有把“服务进程正在运行”当作“Cowork 任务已跑通”。

相关讨论：[上游 #223](https://github.com/javaht/claude-desktop-zh-cn/issues/223)、[#213](https://github.com/javaht/claude-desktop-zh-cn/issues/213)、[未合并的 #224](https://github.com/javaht/claude-desktop-zh-cn/pull/224)。#224 涉及设备级商店更新策略，本 fork 没有采用。
