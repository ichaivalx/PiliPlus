# AGENTS.md

## 工作区定位

- 当前仓库是用户 fork 后的个人工作区。
- `origin` 指向用户自己的 fork：`ichaivalx/PiliPlus`。
- `upstream` 指向原作者仓库：`bggRGjQaUbCoE/PiliPlus`。
- `upstream` 只用于拉取或对比原仓库变化，不作为推送目标。

## 分支要求

- 默认工作分支是 `personal`。
- 所有代码修改、提交、打包和发布相关操作都必须默认在 `personal` 分支上完成。
- 开始修改前先确认当前分支；如果不在 `personal`，先切回 `personal`，除非用户明确要求使用其他分支。

## 上游保护

- 不要向 `upstream` 推送任何内容。
- 不要把本地个人改动主动推向原作者仓库，除非用户明确要求。
- 涉及同步上游时，只允许拉取、查看、对比或合并到本地个人分支，并在执行前说明影响。
