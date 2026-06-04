# 发布说明

## 发布步骤

1. 修改 `Core/Inc/main.h` 里的版本号：

```c
#define VER_MAJOR   1
#define VER_MINOR   0
#define VER_PATCH   0
```

2. 提交代码。

```powershell
git add .
git commit -m "release v1.0.0"
```

3. 在 `CHANGELOG.md` 里添加对应版本的发布记录，例如 `## v1.0.0`。

4. 运行发布脚本。

```powershell
.\scripts\release.ps1
```

正式发布前可以先检查一遍：

```powershell
.\scripts\release.ps1 -DryRun
```

脚本会自动完成：

- 本地 Keil 重新编译
- 生成带版本号后缀的 `.hex/.map/.axf`
- 创建并推送同名 tag，例如 `v1.0.0`
- 用 `CHANGELOG.md` 中对应版本的小节创建或更新 GitHub Release 说明
- 上传发布产物

发布产物会自动上传到 Release，文件名带版本号后缀：

```text
stm32_automation_test_v1.0.0.hex
stm32_automation_test_v1.0.0.map
stm32_automation_test_v1.0.0.axf
```

## 注意事项

- 发布前工作区必须干净，也就是代码已经提交。
- tag 来自 `Core/Inc/main.h`，例如 `1.0.0` 会发布为 `v1.0.0`。
- Release 说明默认来自 `CHANGELOG.md` 里的同名版本小节，例如 `## v1.0.0`；临时覆盖可以传 `-Notes "..."`。
- 编译使用 `MDK-ARM/stm32_automation_test.uvprojx`，和当前 Keil 工程配置一致。
- 本机需要能正常运行 Keil 编译。
- 脚本默认推送到 `origin`，首次使用前需要配置 GitHub 远端。
- 上传 Release 需要 GitHub 登录信息：推荐安装 GitHub CLI 并执行 `gh auth login`；也可以设置 `GITHUB_TOKEN` 环境变量。
- 脚本发布前会检查 git、工作区状态、Keil 路径、GitHub 远端、登录信息、本地/远端 tag 冲突和产物是否齐全。
