# 运行环境与启动

默认双击「奶龙.code.cmd」，不依赖 Windows Script Host。兼容用的 VBS 入口仍保留，但也以 RemoteSigned 启动 Windows PowerShell。分类监听、搜索后台任务、预览和窗口重启使用相同的进程策略。入口不会更改 CurrentUser、LocalMachine 或组织策略。

需要 Windows 10/11、系统自带的 Windows PowerShell 5.1 和图形桌面。PowerShell 7 不作为本版的受支持启动环境。缺少 Office 或系统预览器时，可降级到正文预览；PDF 使用 Windows PDF 渲染；组件仍不支持时可用默认应用打开原文件。OCR 为可选本机能力，语言包缺失或未启用时仍可按文件名搜索、筛选目录和手动分类。

## 下载后的首次启动

当前源码发行版没有可信证书签名，不能把“未签名”描述为“签名已验证”。RemoteSigned 可能阻止带有互联网来源标记的未签名脚本；组织的 AllSigned 等策略也可能要求可信签名。程序不会绕过这些要求。

1. 从项目的 GitHub Releases 下载 ZIP，在终端运行以下命令，将结果与该版本发布信息中的 Windows ZIP SHA-256 比较：

   Get-FileHash -LiteralPath 'C:\你的下载目录\nailong-code-v1.8-windows.zip' -Algorithm SHA256

2. 确认来源与摘要后，在 ZIP 的“属性”中勾选“解除锁定”（若显示）并确定，再解压。只解除你已核对并信任的这个发布包，不要批量解除未知文件。也可以对这个 ZIP 使用 Unblock-File -LiteralPath '完整ZIP路径'。
3. 双击解压目录中的「奶龙.code.cmd」。启动失败时，窗口保留错误信息；依照上面的校验和解除锁定步骤检查。组织策略要求签名时请联系管理员或等待提供可信签名的发行版。

SHA-256 用于核对文件是否与发布页一致；它不能替代可信发布者签名。

## 检查可用组件

界面“更多 → 运行环境”会显示 PowerShell、PDF、OCR、系统预览器注册状态、入口签名与当前策略，以及具体的降级方式。预览器“已注册”表示注册项存在；实际支持情况仍以打开该文件为准。

无需先配置资料库，也可以运行：

   powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\tools\doctor.ps1

加 -Json 输出机器可读诊断。该命令只读取环境，不创建 config.json、不访问个人资料内容、不修改执行策略。

资料库首次使用和资料路径配置仍按 README 操作。测试命令也使用 RemoteSigned；由测试程序本机生成的隔离脚本不需要互联网来源豁免。

参考：
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash?view=powershell-5.1
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file?view=powershell-5.1
