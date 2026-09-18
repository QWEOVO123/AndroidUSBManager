# USBManager Windows 后端

无界面的 C# 后台程序，扫描手机临时认证 WinUSB 接口，完成电脑配对和已知身份识别。配合本仓库的 Android 模块使用。

## 使用

Release 中的 `USBManagerWinBackEnd-win-x64.zip` 面向 Windows x64，包含自带 .NET 运行时的程序，无需另装 .NET。完整解压后双击 EXE；没有窗口是正常现象。进程运行期间，手机可发起配对。

可选开机登录自启（当前用户，无需管理员权限）：

```powershell
.\USBManagerWinBackEnd.exe --install
```

该命令只注册自启；要立即运行，请另行双击 EXE。首次配对必须在手机上发起授权。

删除登录自启项：

```powershell
.\USBManagerWinBackEnd.exe --uninstall
```

移除自启不终止已经运行的进程；需要时在任务管理器退出，再删除解压目录。

日志与 DPAPI 加密的身份私钥保存在 `%LOCALAPPDATA%\USBManagerWinBackEnd`。不要公开上传 `identity.dpapi`；删除它将改变电脑身份，需要重新配对。

## 源码构建

需要 .NET 8 SDK：

```powershell
dotnet publish windows-backend/USBManagerWinBackEnd.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist/windows-backend-win-x64
```

协议：ECDSA P-256、临时 ECDH P-256、HKDF-SHA256、AES-256-GCM。当前是手机认证电脑，不是双向长期设备身份认证。

随主项目使用木兰公共许可证第 2 版，见根目录 LICENSE。
