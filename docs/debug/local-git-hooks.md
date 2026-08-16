# Local Git Hooks

Last updated: 2026-08-15 (Asia/Taipei)

## 決策

Repository追蹤`.githooks/pre-commit`，但不預設啟用。每個working copy必須自行執行：

```bash
./scripts/configure_git_hooks.sh enable
```

這個分界很重要：hook內容屬於codebase，`core.hooksPath`則是本機Git設定，不應在clone或build時
被悄悄改寫。

## 耗時證據

2026-08-15在目前開發機實測同一份`./scripts/verify.sh`：

- 全新獨立cache：39.88秒。
- 已有build cache：6.48秒。
- 兩次都通過262個Core tests（3個live tests依設計skip）、正式Xcode App build、4個App-layer
  tests、shipping Fixture boundary與diff whitespace checks。

這些數字只代表目前硬體與當時cache狀態，不是固定效能保證。驗證完全腳本化，不呼叫LLM。

## 安全行為

- Hook只呼叫版本化的`./scripts/verify.sh`，避免hook與手動驗證產生兩套規則。
- `verify.sh`明確移除live／Archive acceptance opt-in，因此pre-commit不會送出lifecycle request。
- 驗證失敗會阻止commit，但不修改staged或working-tree內容。
- 設定腳本在已有其他`core.hooksPath`時fail closed，不覆蓋使用者原本的hooks。
- `disable`只會移除本專案自己設定的`.githooks`，不會清除不認得的設定。

## 操作

```bash
./scripts/configure_git_hooks.sh status
./scripts/configure_git_hooks.sh enable
./scripts/configure_git_hooks.sh disable
```

Git本身仍支援`git commit --no-verify`，但那是明確略過本機保護的例外操作，不應成為日常流程。
