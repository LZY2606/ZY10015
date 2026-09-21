# Verification entry points (`eng/`)

Cross-platform, single-source-of-truth verification for the whole repository.

| File | Purpose |
| --- | --- |
| `verify.sh` | Unix thin entry point. Runs `verify.core.sh` with `sh`. |
| `verify.ps1` | Windows thin entry point. Invokes the same `verify.core.sh` through Git for Windows `sh.exe`. |
| `verify.core.sh` | The only place stages and their parameters are defined (POSIX `sh`). |
| `tools/PackageInspector.cs` | File-based .NET program (`dotnet <file>`, no project/restore). Audits `.nupkg`/`.snupkg` contents, rewrites them into a canonical form and emits SHA256 hashes. |
| `tools/Rid.cs` | File-based helper that prints the current .NET RID (used by the optional AOT leg). |

## Stages

1. `sdk-preflight` - verifies the SDK pinned by [`global.json`](../global.json) (`10.0.101`,
   `rollForward: latestFeature`) using `dotnet --list-sdks`. A missing/wrong SDK fails in well
   under a second with the exact pin, the installed SDKs and copy-pasteable install commands.
2. `restore-locked` - `dotnet restore NCalc.slnx --locked-mode`. Dependencies are pinned in the
   committed `packages.lock.json` files. The global NuGet package folder is passed as a source
   (plus nuget.org), so after the one-time restore every later stage works fully offline.
3. `build-release` - Release build of every project and TFM
   (`net462`, `netstandard2.0`, `net8.0`, `net10.0`).
4. `test` - runs the complete TUnit suite through the Microsoft.Testing.Platform host.
5. `source-generators` - two fully isolated restores+builds of `NCalc.Core` that emit compiler
   generated files; the `NCalc.SourceGenerators` outputs must be byte-identical. The probes run
   under `artifacts/sg/` and never touch the shared build intermediates.
6. `pack` - `dotnet pack` for the unsigned Release packages.
7. `pack-signed` (build then pack) - deterministic `SignedRelease` build and pack for
   `NCalcSync.signed`.
8. `package-audit` - package content audit + canonical hashes (see below).

With `NVERIFY_AOT=true` (CI `aot` matrix leg) two extra legs publish and execute a Native AOT
test binary.

## One-time preparation (not part of the demo)

```sh
dotnet restore NCalc.slnx
```

After this restore succeeds (packages are in the global NuGet folder) the network can be
unplugged; `sh eng/verify.sh` replays restore, build, tests, generator check and packing offline.

## Run

From the repository root only (the scripts derive the root from their own location, but the
canonical invocation is root-relative):

```sh
sh eng/verify.sh
```

Windows (PowerShell; Git for Windows provides `sh.exe`):

```powershell
.\eng\verify.ps1
```

Optional AOT leg (same matrix as the upstream CI, `aot=false/true`):

```sh
NVERIFY_AOT=true sh eng/verify.sh
```

Nothing version-controlled is modified; all outputs live under the git-ignored
[`artifacts/`](../artifacts) directory, which is recreated at the start of every run.

## What success looks like

Each stage prints `==> [n/total] <stage>` when it starts and
`<== [n/total] <stage> OK (duration)` when it passes. The final summary lists every stage with
its elapsed time and the canonical SHA256 of every package:

```text
================ verification summary ================
PASS  sdk-preflight                    0s
PASS  restore-locked                   1s
PASS  build-release                    7s
PASS  test                             3s
PASS  source-generators                6s
PASS  pack                             1s
PASS  pack-signed                      2s
PASS  pack-signed                      1s
PASS  package-audit                    1s
TOTAL                               21s

Package                        SHA256 (normalized)
NCalc.7.3.0-alpha.nupkg        27a2af67...
...
```

Failures preserve the failing tool's raw exit code and print the path to the full stage log,
e.g. `artifacts/logs/04-test.log`. No error is swallowed (commands are not hidden behind pipes
that would mask their exit status).

## Offline replay and reproducible package hashes

- Locked restore + global-package-folder sources make stages 2-8 work with no network after the
  first restore.
- Release builds set `Deterministic`, `ContinuousIntegrationBuild` and a `PathMap` that maps the
  disposable `artifacts/` root and the checkout to constant prefixes, so source paths, PDB GUIDs
  and PE timestamps do not vary.
- `dotnet pack` itself stamps OPC relationship IDs, core-properties GUIDs and timestamps into the
  raw `.nupkg`. `PackageInspector` canonicalizes those parts (fixed entry order, fixed 1980
  timestamps, constant IDs, deterministic core-properties part name), so the **normalized**
  package bytes - and therefore the SHA256 in `artifacts/packages.sha256` - are identical across
  consecutive runs. Running `sh eng/verify.sh` twice yields the same set of hashes.

## Artifacts layout

Everything is disposable and lives under `artifacts/` (never committed):

- `artifacts/bin/`, `artifacts/obj/` - build outputs and intermediates
- `artifacts/package/release/`, `artifacts/package/signedrelease/` - raw `.nupkg`/`.snupkg`
- `artifacts/tools/normalized/` - canonicalized packages whose hashes are compared
- `artifacts/packages.sha256` - `sha256  <relative normalized package path>` per package
- `artifacts/sg/` - isolated source-generator probes
- `artifacts/logs/NN-<stage>.log` - full output of every stage

## Package content policy

`PackageInspector` fails the audit if any package entry contains:

- a `test`/`tests`, `example`/`examples`, `playground` or `benchmark` path segment
- a `*.log` file
- the absolute repository path

So test, example/playground and benchmark projects/assemblies, temporary logs and absolute
paths can never be shipped.
