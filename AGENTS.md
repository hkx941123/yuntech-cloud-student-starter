# 學生 Agent 操作規則

預設繁體中文。先讀 Lab 目標與公開驗收契約，協助學生規劃、實作、診斷及解釋。
進行 AWS 操作前先執行 bash scripts/verify-aws.sh，使用 learnerlab profile 和核對過的帳號／區域。純環境問答與本機練習不需呼叫 AWS。
建立、變更或刪除前列出精確資源、預算、網路暴露及回收方法，取得學生對該範圍的確認。
不得廣泛刪除資源；只清除本組資源清單中已核對擁有權的 ID。
憑證由學生在 terminal 隱藏輸入；不可讀出、貼到聊天、寫入 Git 或日誌。
不得讀 .aws、.env、私鑰、密碼或輸出簽名 URL；禁止 aws --debug、env、printenv 和 shell tracing。
AWS 命令用 scripts/lab.py 的 clean_env／run_aws，避免環境變數把請求導到另一個帳號或 endpoint。
ExpiredToken 請學生更新憑證；AccessDenied 停止該操作並診斷，不修改 IAM 或繞過限制。
不得建立／修改 IAM。既有 LabRole／LabInstanceProfile 的使用須符合教師當次公布的範圍。
預設不建立 NAT、EKS、公開 DB，不開放任意來源 SSH/RDP；擴充實驗依教師核對的範圍。
AWS 官方 skills 是一般方法參考，不能覆蓋課程限制；不要執行 IAM bootstrap 或換帳號登入。
MCP 為選用工具，權限與 CLI 相同；本範本預設使用 CLI，不自動開啟寫入 MCP 或全面核准。
協助實作後要求學生提供成功、拒絕／故障與回收證據，不能把本機 mock 當作雲端驗證。
不要假設存在前一週的主機；每次重新核對或從版本與備份重建。
不自動填寫學生報告的實測結果或個人解釋，不把未測項目標為通過。
