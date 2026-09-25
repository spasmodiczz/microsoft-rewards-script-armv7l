# 上游 CI 工作流（已停用，仅作参考）

这里存放的是上游仓库 `.github/workflows/` 的原始文件，**在本仓库中不生效** ——
它们被从 `.github/workflows/` 移到了这里。

## 为什么移动

1. **它们对本仓库根本不会触发。** 三个工作流的触发条件都绑定上游的 `v3` / `v4` 分支：

   | 文件 | 触发条件 | 在本仓库（`main` 分支） |
   |---|---|---|
   | `auto-release.yml` | `push` 到 `v3` / `v4` 且改动 `package.json` | ❌ 永不触发 |
   | `format-main.yml` | `push` 到 `v4` / `v3` | ❌ 永不触发 |
   | `format-check.yml` | 任何 `pull_request` | ⚠️ 只对 PR 生效 |

2. **推送工作流文件需要额外的 GitHub 权限。** GitHub 规定：使用 Personal Access Token
   推送或修改 `.github/workflows/` 下的文件，token 必须额外具备 **Workflows** 权限
   （细粒度 token 为 `Workflows: Read and write`，经典 token 为 `workflow` scope）。
   本仓库发布时使用的 token 没有该权限，为不扩大授权范围，选择移出该目录。

## 想恢复上游 CI 怎么办

**方式一：恢复文件并给 token 加权限**

```bash
mkdir -p .github/workflows
git mv docs/upstream-ci/auto-release.yml  .github/workflows/
git mv docs/upstream-ci/format-check.yml  .github/workflows/
git mv docs/upstream-ci/format-main.yml   .github/workflows/
git commit -m "ci: 恢复上游工作流"
git push
```

推送时使用具备 `Workflows: Read and write`（或经典 `workflow` scope）的 token。

**方式二：按本仓库的实际分支改造**

如果只想要「格式检查」，把 `format-check.yml` 里的触发分支改成本仓库实际使用的分支即可：

```yaml
on:
    push:
        branches: ['main']
    pull_request:
```

## 注意

- 这些文件是**上游原样拷贝**，未做任何修改。
- 放在 `docs/` 下不会被 GitHub 当作工作流执行（只有 `.github/workflows/` 是特殊目录）。
