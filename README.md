# mullvad-autobuild

这个仓库会通过 GitHub Actions 每天自动检查并构建 Mullvad VPN 的 Linux `x86_64` RPM。

当前支持 3 个渠道：

- `stable`：上游最新正式 release tag
- `beta`：上游最新 prerelease/beta tag
- `main`：上游 `main` 分支最新 commit

## 行为说明

- 定时触发：每天一次
- 手动触发：支持从 Actions 页面选择 `stable`、`beta`、`main` 或 `all`
- 跳过策略：
  - `stable` / `beta`：如果当前仓库对应 release 已记录相同上游 tag，则跳过
  - `main`：如果当前仓库对应 release 已记录相同 commit SHA，则跳过
- 发布位置：当前仓库 GitHub Releases

每个渠道使用固定 release tag：

- `autobuild-stable-x86_64`
- `autobuild-beta-x86_64`
- `autobuild-main-x86_64`

每次新构建都会删除同渠道旧资产，再上传新的 RPM，保证每个渠道只保留最新包。

## 手动运行

在 GitHub 仓库页面打开 `Actions`，运行 `Build Mullvad RPMs`：

- `channel=all`：构建全部渠道
- `channel=stable|beta|main`：仅构建单个渠道
- `force=true`：即使上游版本未变化也强制重建
- `manual_ref=<tag|branch|commit>`：手动指定要构建的版本
- `manual_ref_type=auto|tag|commit`：指定 `manual_ref` 的解释方式

示例：

- 手动构建指定正式版：`channel=stable`，`manual_ref=2026.1`，`manual_ref_type=tag`
- 手动构建指定 beta：`channel=beta`，`manual_ref=2026.2-beta1`，`manual_ref_type=tag`
- 手动构建指定主线 commit：`channel=main`，`manual_ref=<commit sha>`，`manual_ref_type=commit`

## Release 元数据

每个自动发布的 release body 会写入机器可解析字段：

- `upstream_channel`
- `upstream_ref`
- `upstream_sha`
- `built_at`
- `source_url`
- `artifact_name`

这些字段同时也是 workflow 的跳过依据。

## 注意事项

- 工作流会从 `mullvad/mullvadvpn-app` 拉取源码并初始化必要 submodule
- 构建使用上游的 `./build.sh --optimize`
- 只发布 `MullvadVPN-*x86_64.rpm`
- 当前实现不做 GPG 重签名，也不保留旧版本归档

## 本地检查

可以先做最基础的脚本语法检查：

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
```
