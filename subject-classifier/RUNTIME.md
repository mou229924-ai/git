# 运行环境与启动

默认双击「奶龙.code.cmd」，不依赖 Windows Script Host。兼容用的 VBS 入口仍保留，但也以 RemoteSigned 启动 Windows PowerShell。分类监听、搜索后台任务、预览和窗口重启使用相同的进程策略。入口不会更改 CurrentUser、LocalMachine 或组织策略。

需要 Windows 10/11、系统自带的 Windows PowerShell 5.1 和图形桌面。PowerShell 7 不作为本版的受支持启动环境。缺少 Office 或系统预览器时，可降级到正文预览；PDF 备用预览使用 Windows PDF 渲染，组件仍不支持时可用默认应用打开原文件。发布包自带离线 PdfPig 解析器，带文字层 PDF 的正文索引与 OCR 开关、Windows PDF 渲染组件无关。OCR 为可选本机能力，扫描页与图片识别需要可用语言包。

## 下载后的首次启动

当前源码发行版没有可信证书签名，不能把“未签名”描述为“签名已验证”。RemoteSigned 可能阻止带有互联网来源标记的未签名脚本；组织的 AllSigned 等策略也可能要求可信签名。程序不会绕过这些要求。

1. 从项目的 GitHub Releases 下载 ZIP，在终端运行以下命令，将结果与该版本发布信息中的 Windows ZIP SHA-256 比较：

   Get-FileHash -LiteralPath 'C:\你的下载目录\下载的Windows发布包.zip' -Algorithm SHA256

2. 确认来源与摘要后，在 ZIP 的“属性”中勾选“解除锁定”（若显示）并确定，再解压。只解除你已核对并信任的这个发布包，不要批量解除未知文件。也可以对这个 ZIP 使用 Unblock-File -LiteralPath '完整ZIP路径'。
3. 双击解压目录中的「奶龙.code.cmd」。启动失败时，窗口保留错误信息；依照上面的校验和解除锁定步骤检查。组织策略要求签名时请联系管理员或等待提供可信签名的发行版。

SHA-256 用于核对文件是否与发布页一致；它不能替代可信发布者签名。

## PDF 解析边界

PDF 正文提取在独立后台进程中运行，默认最多 100 页、25 MiB、15 秒，工作进程私有内存监控阈值为 256 MiB；字符数受索引设置限制。达到资源限制、页面损坏或部分扫描页未识别时，保留已完成正文，并在任务诊断及日志中说明原因。扫描页仅在启用 OCR 后补充识别，语言包缺失不会阻止已有文字层进入索引。参数位置和重建索引说明见 [README](README.md)。随包第三方许可与版本来源见 `third-party/pdfpig`。

## 检查可用组件

界面“更多 → 运行环境”会分别显示 PowerShell、PDF 文字层组件、Windows PDF 渲染、OCR、系统预览器注册状态、入口签名与当前策略，以及具体的降级方式。PDF 文字层诊断只核对解析器、依赖和工作进程文件是否齐全，不读取任何个人 PDF；单份文档能否提取及是否完整，以实际任务结果为准。预览器“已注册”表示注册项存在；实际支持情况仍以打开该文件为准。

无需先配置资料库，也可以运行：

   powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\tools\doctor.ps1

加 -Json 输出机器可读诊断。该命令只读取环境，不创建 config.json、不访问个人资料内容、不修改执行策略。

资料库首次使用和资料路径配置仍按 README 操作。测试命令也使用 RemoteSigned；由测试程序本机生成的隔离脚本不需要互联网来源豁免。

参考：
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash?view=powershell-5.1
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file?view=powershell-5.1
