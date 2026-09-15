# 開始使用

1. 接受教師 Classroom 邀請或從本 template 建立自己的作業 repo，再開 2-core Codespace。
2. 等 creation log 出現 `Environment check passed` 與 `Next: bash scripts/set-learnerlab-credentials.sh`，再執行 `bash .devcontainer/scripts/verify-environment.sh`。SSH 可連／Available 並不單獨證明套件已裝好。
3. AWS Academy Start Lab 變綠後，在 AWS Details 找本次三個憑證值。
4. 在自己的 terminal 執行 `bash scripts/set-learnerlab-credentials.sh`，填帳號、region 與三個隱藏值。不要貼到聊天。
5. 執行 `bash scripts/verify-aws.sh`；身分比對不能單靠 STS 證明帳號屬於 Academy，需自行核對 console。
6. 選擇 [OpenCode Terminal Agent](opencode.md)（執行 `opencode`，預設 Big Pickle），或 VS Code 登入自己的 Copilot 並開 Agent。請它讀 AGENTS.md 及當週 Lab，先提出實作與驗收計畫；同一時間先用一個 Agent。
7. 完成基本自查：`bash scripts/validate.sh`。這不是雲端作品已完成的證明。

Learner Lab 重啟／ExpiredToken 時重做第 4–5 步；Codespace 重啟後外連 IP 可能改變。
每次只 stage 自己檢查過的檔案，先看 git diff，再 python3 scripts/verify-repo.py、commit、push。
停 Codespace／關 browser 都不會清除 AWS；先依資源清單清除並驗證再 End Lab。
跨週保留程式和去識別化證據，資料備份在核准位置；不要假設主機持續存在。
