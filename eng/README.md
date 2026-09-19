# eng/ — 跨平台验证入口

`eng/verify.sh` 是仓库唯一的验证核心（阶段与参数只在此维护一份）；`eng/verify.ps1`
是 Windows 薄入口，仅定位 Git Bash 并转发参数。`eng/tools/package-utils.cs`
是 .NET 10 file-based 小工具，负责包的确定性规范化与内容校验（无外部包依赖，可离线运行）。

## 用法

```sh
dotnet restore NCalc.slnx   # 准备阶段（一次性，不计入验证耗时）
sh eng/verify.sh            # 从仓库根目录运行完整验证
```

Windows PowerShell：

```powershell
./eng/verify.ps1            # 等价入口，转发到 eng/verify.sh
```

## 验证阶段

| 阶段 | 内容 |
| --- | --- |
| `sdk-check` | 解析 `global.json`，校验本机 SDK 满足版本与 `rollForward`；缺失时数秒内给出安装诊断，不会拖到构建深处才失败 |
| `restore` | `dotnet restore --locked-mode`，严格按各项目 `packages.lock.json` 校验，不升级依赖、不联网补齐缺失输入 |
| `build` | `dotnet build NCalc.slnx -c Release --no-restore` |
| `test` | `dotnet test --project test/NCalc.Tests/NCalc.Tests.csproj -c Release --no-restore`（TUnit / Microsoft.Testing.Platform） |
| `sourcegen-consistency` | 对 `net462;netstandard2.0;net8.0;net10.0` 各构建两次并 `diff` source generator 产物，保证生成一致 |
| `pack` | `dotnet pack -c Release --no-build`，随后规范化 nupkg/snupkg（固定 zip 时间戳、确定性 psmdcp 命名），保证连续两次运行产物哈希一致 |
| `package-check` | 校验包内无 test/example/临时日志/绝对路径，输出每个包的 sha256 与整体 manifest 哈希 |

成功时打印各阶段耗时与最终包哈希；任一阶段失败即终止，保留该阶段原始退出码，
完整输出保存在 `artifacts/logs/<stage>.log`。

演示输出（节选）：

```text
==> stage: sdk-check
    [sdk-check] ok (0s)
...
================ verify summary ================
sdk-check                       0s
restore                         2s
build                           8s
test                            7s
sourcegen-consistency          18s
pack                            6s
package-check                   2s
TOTAL                          43s

packages (artifacts/nuget, sha256):
<sha256>  NCalc.7.3.0-alpha-....nupkg
...
manifest-sha256: <sha256>
VERIFY OK
```

## 离线重放

`restore` 阶段完成后，后续阶段全部使用 `--no-restore` / `--no-build`，切断网络
即可重放：

```sh
sh eng/verify.sh --skip-restore   # 跳过恢复阶段，纯离线重放
```

已填充全局包目录（`~/.nuget/packages`）时，即使不跳过 `restore`，锁定模式恢复
也只校验本地缓存，不会访问公网。

## 产物位置

- `artifacts/nuget/` — 规范化后的 `.nupkg` / `.snupkg`，以及 `SHA256SUMS.txt`、`SHA256SUMS.txt.sha256`
- `artifacts/logs/` — 各阶段完整日志
- `artifacts/sourcegen/` — source generator 两轮生成物（供排查差异）

`artifacts/` 已加入 `.gitignore`；验证脚本不会修改任何受版本控制的文件。

## 锁定依赖

恢复使用各项目旁边的 `packages.lock.json`（已提交）。依赖变更后需显式更新锁文件：

```sh
dotnet restore NCalc.slnx -p:RestorePackagesWithLockFile=true --force-evaluate
```

## CI

`.github/workflows/build-test.yml` 在 ubuntu / windows / macos 矩阵上调用同一入口
（Unix 用 `sh eng/verify.sh`，Windows 用 `eng/verify.ps1`），SDK 版本由 `global.json`
决定，并缓存全局包目录 `~/.nuget/packages`（而非仓库输出目录）。
