# 在 Codespace Terminal 使用 OpenCode

本 repo 預裝 OpenCode 1.18.30，預設 `opencode/big-pickle`。Agent 在 Codespace 執行工具，模型在遠端提供；不需要下載大型模型，也不需要 GPU。Copilot 仍可使用，相同時間先選一個 Agent 操作工作區。

## 第一次啟動（不需要 AWS Lab）

1. 從本範本建立自己的作業 repo，開啟 Codespace，等 post-create 完成。
2. VS Code → Terminal → New Terminal，在 repo 根目錄執行：

   ```bash
   bash .devcontainer/scripts/verify-environment.sh
   opencode
   ```

3. 確認顯示 `lab` Agent 與 Big Pickle；可用 `/models` 查看選擇。本範本只列指定模型，主模型與輔助模型都固定。
4. 輸入：`請用繁體中文讀取 README.md 與兩份 Lab 任務，列出 W1、W2 的目標。這次只讀檔，不執行 AWS 或修改檔案。`
5. 觀察工具讀檔及回覆；需要核准時，先看命令／差異，再選本次允許（once），不要選永久允許或 auto。

官方程式支援無 API key 的免費模型路徑，但供應商可調整可用性及限制。若出現登入／付款／限流／模型不可用，先記錄錯誤並回報教師；不要為了完成課程自行綁卡或更換付費模型。免費不代表 Codespace 運算與 AWS 資源免費。

## 開始當週 AWS 任務

1. 在另一個 Terminal 執行 `bash scripts/set-learnerlab-credentials.sh`，由你自己隱藏輸入本次 AWS Details；不要貼到 Agent。
2. 執行 `bash scripts/verify-aws.sh`，確認自己的帳號與 region。
3. 回到 OpenCode，輸入 `/lab-plan labs/02-private-s3/README.md`（換成當週路徑）。
4. 先解釋你預期的結果，再請 Agent 完成一個小步驟。AWS 變更先核對精確資源、成本、網路暴露及回收方式。
5. 用另一條證據核對結果：例如授權下載成功與匿名拒絕對照；按報告模板自行記錄。
6. 完成精確回收、檢查 Git diff、排除秘密後才提交。OpenCode 的 `/undo` 不會撤回 AWS 資源變更。

## 下週教師試跑與問題回報

先依[開始使用](getting-started.md)及當週 Lab 操作。卡住時記錄：週次／步驟、repo commit SHA、OpenCode 版本／模型、經去敏感處理的命令與錯誤、預期與實際、有無 AWS 資源殘留。不要附 keys、原始會話、signed URL 或密碼截圖。

這套安裝不會自動開始 Agent 會話、呼叫模型或啟動 AWS。既有 Codespace 更新 repo 後需 Rebuild Container，或在 terminal 執行 `bash .devcontainer/scripts/install-opencode.sh` 再做環境自查。課綱、PPT 及正式學習單由課程 Agent 依教師試跑回饋同步。

## 資料與限制

Big Pickle 目前為限時免費，免費期間收集的資料可能用於模型改進。只用合成資料，不傳個資或機密。會話分享在本 repo 停用；原始會話留在工具自己的本機儲存，不要加入 Git。權限提示不能保證任意腳本安全，仍需檢查腳本內容。

來源（2026-09-13 核對）：[安裝](https://opencode.ai/docs/)、[權限](https://opencode.ai/docs/permissions/)、[模型與隱私](https://opencode.ai/docs/zen/)、[CLI](https://opencode.ai/docs/cli/)。教師相容性實測紀錄保留在教師 repo，不提供學生解答。
