# W3 Sprint：巡檢服務雛型上線

## 這週要做什麼

W2 你把巡檢紀錄私有保存在 S3。這週把**巡檢服務本身**放上雲端：在一台雲端主機上執行一支小程式，打開 `/health` 就看得到「服務正常，版本是哪一個 commit」。

之後每週都在同一支服務上加功能（W4 事件、W5 資料庫……）。主機每週都可能被刪掉重開，所以這週還要練習：**從 repo 的同一個 commit，幾分鐘內把服務重建出來。**

**分組方式：個人部署、小組協作。** 3–4 人一組。每個人在自己的 Learner Lab 帳號部署自己的一台主機，不共用憑證。小組共用同一個 repo commit，負責互相審查計畫、比對結果、分工觀察故障與交叉驗收。每張任務卡輪一位組員當審查者。

## 先懂這些名詞

投影片會逐一講解，這裡是給你回查用的一句話說明。

| 名詞 | 一句話說明 | 本週用在哪裡 |
|---|---|---|
| EC2 instance | AWS 上的一台虛擬主機 | 你的服務跑在上面 |
| AMI | 主機開機用的系統映像檔；本週用 Amazon Linux 2023（AL2023） | T1 選 AMI |
| 預設 VPC、預設子網 | Learner Lab 帳號裡已經建好的私人網路與其中一段位址範圍 | 主機放在這裡，不自己新建 |
| IGW、路由表 | IGW 是 VPC 通往網際網路的出入口；路由表決定封包往哪走。子網實際使用的路由表裡有 `0.0.0.0/0 → igw-…`，這個子網才是「公有」 | T1 核對 |
| Security Group（SG） | 主機外面的防火牆規則：誰、從哪裡、可以連哪個 port | 只放行 TCP 80、22 |
| `/32` | 只代表「一個」IP 位址的寫法，例如 `203.0.113.5/32` | SG 來源只寫你的 Codespace |
| key pair | SSH 登入用的一對鑰匙：公鑰交給 AWS，私鑰只留在你的 Codespace | 登入主機看狀況 |
| user data、cloud-init | user data 是開機時交給主機的腳本；cloud-init 是主機上負責執行它的程式 | 自動安裝並啟動服務 |
| nginx | 站在門口的網頁伺服器，收到請求再轉給後面的程式（反向代理） | 聽 port 80 |
| inspection 服務 | 教師提供的巡檢服務雛型，由 systemd 負責啟動與重啟 | 聽 `127.0.0.1:8080` |
| `127.0.0.1`（loopback） | 只有主機自己連得到的位址 | 8080 不需要、也不能在 SG 開 |
| commit SHA | Git 為每個 commit 產生的 40 字元編號 | `/health` 回報的 version |

## 一次請求怎麼走到你的程式

```text
你的 Codespace（出口 IPv4）
   │ HTTP，TCP 80
   ▼
IGW → 路由表 → 預設公有子網
   ▼
Security Group：只允許你的 Codespace /32 連 80、22
   ▼
EC2 主機（AL2023、t3.micro）
   ├─ nginx：聽 80，轉給 127.0.0.1:8080
   └─ inspection 服務：/health → {"status":"ok","service":"inspection","version":"<commit SHA>","started_at":"<UTC>"}
```

故障時先問：請求走到哪一關停住了？

## 教師提供與你要完成的部分

教師提供：[服務雛型](../../app/service.py)、[nginx 設定](../../deploy/nginx.conf)、[user data 打包器](../../deploy/make-user-data.sh)、[個人資源清單範本](../../deploy/resources.example.md)。

你要完成：核對網路、請 Agent 產生部署計畫並經同學審查、請 Agent 把建立與回收寫成**你自己 repo 裡的腳本**並審查後執行、診斷受控故障、回收並用腳本重建。教師**不提供** AWS 建立／刪除腳本、預填的結果或任何帳號資源 ID。

**範圍**：同一時間只有一台主機；AL2023 x86_64、t3.micro；放在預設 VPC 的預設公有子網；根磁碟加密、類型 gp3、主機終止時一起刪除（DeleteOnTermination）；IMDSv2 設為 required。

**標籤**：`course=yuntech-115-1`、`week=w03`、`group=<組名>`、`owner=<你的組內代號，不用學號>`。

**本週不做**：HTTPS（W6）、事件 API、資料庫、第二台同時運作的主機、NAT Gateway、Elastic IP、負載平衡器、新建 VPC、修改 IAM。

## 開始前

1. 依 [環境步驟](../../docs/getting-started.md) 開好 Codespace、設定暫時憑證，執行 `bash scripts/verify-aws.sh`，確認是自己的帳號、區域為 us-east-1。
2. 讀 [Agent 規則](../../AGENTS.md)。AWS 指令一律透過 `scripts/lab.py` 的 `clean_env`／`run_aws` 執行，不要用其他方式切換帳號或 endpoint。
3. 複製一份 [個人資源清單範本](../../deploy/resources.example.md)，之後每建立一項資源就立刻記下它的 ID。

## 任務卡

| 卡 | 每人自己做 | 小組一起做 | 完成條件與證據 |
|---|---|---|---|
| T1 規劃與核對 | 核對身分、區域、網路、AMI、來源 /32；請 Agent **只提出**部署計畫 | 兩兩交換審查，審查者簽核後才執行 | 計畫列出精確網路、AMI、/32、資源類型、費用來源與回收清單；未核准前不建立任何資源 |
| T2 部署雛型 | 請 Agent 把建立步驟寫成 `deploy/up.sh`（規格見下方），審查後執行：建立專用 SG、key pair、一台主機並部署雛型 | 全組用同一個 commit；比對每人的 version 與就緒時間 | 五層的首次觀測時間（見下方）；另記服務還沒好時的一次 curl 真實結果；version 等於組內 commit |
| T3 受控故障 | 先寫預測，再做兩個故障並逐一恢復：(a) 移除 SG 的 80 規則，再加回完全相同的規則；(b) 停止 inspection 服務（nginx 保留），再啟動 | 指定一人示範 (c) 停止 nginx，全組比較三種失敗樣子 | 每人的 (a)(b) 都有「預測／實際／原因／恢復後結果」；組內報告三種故障齊全 |
| T4 回收、重建、保留 | 用 `deploy/down.sh` 以 ID 回收第一台並讀回五項都不存在；再用 `deploy/up.sh` 從同一個 commit 重建第二台、核對版本；最後把第二台**停止（Stop）保留到下週** | 比較每人的重建秒數；互相核對回收讀回與保留清單 | 第一台五項讀回不存在；第二台已停止，並列在保留清單；兩支腳本已 commit |

### T1 的核對項目

- 預設 VPC、預設子網與所在的可用區（AZ）。
- 這個子網**實際使用**的路由表（子網沒有明確關聯時，看 VPC 的 main route table）裡有 `0.0.0.0/0 → igw-…`。沒有預設網路就停下來求助，不要自己新建。
- AL2023 AMI 的名稱、架構 x86_64、建立日期。
- 你的 Codespace 對外 IPv4，換算成 `/32`。
- SG 入站只能有 TCP 22、80，來源都是這個 `/32`；不得出現 `0.0.0.0/0` 或 `::/0`。

### 建立與回收腳本規格（T2、T4）

下週起不必再請 Agent 重新規劃：直接執行審查過的腳本即可，也能省下 Agent 的用量。

1. `deploy/up.sh` 只建立本週範圍：1 個 SG、1 個匯入的 key pair、1 台主機。來源 `/32`、組名、組內代號、部署 commit 由參數或 `.local/` 的設定檔提供；不寫死帳號，不含任何憑證或私鑰。
2. 每建立一項，立刻把 ID 寫進 `.local/resources.json`（`.local/` 不進 Git）；報告再抄錄。
3. `deploy/down.sh` 只處理 `.local/resources.json` 裡的 ID，刪除前核對標籤；不得依名稱搜尋後大量刪除。`down.sh --stop` 只停止主機、不刪除。
4. 兩支腳本都要讀回：`up.sh` 結束時確認健康頁 200 且版本等於 commit；`down.sh` 結束時確認五項都不存在（`--stop` 則確認主機為 stopped）。
5. 執行前先印出「將要建立或刪除的清單」並等你確認；不使用永久自動核准。腳本要 commit，審查者在報告簽核。

### T2 的部署步驟與五層紀錄

1. SSH 私鑰（ed25519）由工具在 Codespace 的 `~/.ssh` 產生，權限 600；Agent 不讀取內容，也不放進 Git。只把公鑰匯入 AWS 成為 key pair。第一次連線要核對主機指紋，不關閉主機金鑰驗證。
2. 程式有修改就先 commit，再打包成 user data（`up.sh` 應該自己呼叫這一步；手動執行只用來檢查打包結果）：

   ```bash
   bash deploy/make-user-data.sh HEAD .local/w03-user-data.sh
   ```

   打包器只取該 commit 的 `app/service.py` 與 `deploy/nginx.conf`，並寫入完整 SHA；還沒 commit 的修改不會被打包。主機上不 clone 你的私有 repo，也不放任何 token。產生的 user data 小於 16 KiB；交給 AWS CLI 時注意它會不會再做一次 base64 編碼，避免重複編碼。
3. 主機變成 running 後，**馬上** curl 一次 `/health`，記下失敗的樣子。
4. 依序記下每一層**第一次觀測到**的 UTC 時間：
   - 主機狀態 running
   - 狀態檢查 2/2 通過
   - cloud-init 完成（`cloud-init status --wait`，記執行前後時間與結果）
   - nginx 在 80、inspection 在 127.0.0.1:8080 監聽
   - `/health` 回 200，而且 version 等於部署的 commit

觀測到的順序不一定等於實際完成的順序；running 也不代表 `/health` 已經可用。

## 成功與故障契約

- **成功**：`/health` 回 200，JSON 含 `status=ok`、`service=inspection`、`version=<40 字元 commit SHA>`、`started_at=<UTC>`。
- **(a) SG 擋住**：用有逾時上限的 curl（例如 `--max-time 8`）發出新的 HTTP 連線，記錄失敗的樣子與耗時。
- **(b) 後端停止**：nginx 還在、inspection 停了；觀察 HTTP 狀態碼與耗時，推論請求到了哪一層。
- **紀錄 curl 時**：curl 的結束碼（exit）和 HTTP 狀態碼是兩件事，兩個都要記。HTTP 000 表示沒有收到任何 HTTP 回應。
- **教師延伸**：停止 nginx 的拒絕連線對照；讓 `/health` 多回報主機所在的 AZ；SSM 只在教師核准後短暫測試，不作為必修通道，也不修改 IAM。

## 常見狀況

- **筆電瀏覽器打不開你的服務**：你筆電的 IP 不是 Codespace 的 IP。不要為了截圖放寬 SG；可以在 Codespace 內做受限的 HTTP 轉送，用 private forwarded port 在瀏覽器看，報告註明「轉送檢視」。
- **Codespace 重啟後連不上**：Codespace 的對外 IPv4 可能變了。重新查出口 IP，列出精確的舊／新 `/32`，經審查者核准後替換，不放寬來源。
- **同一個卡點超過 10 分鐘**：記下最後成功的那一層與錯誤訊息，再求助。
- **下課前 40 分鐘**：不管做到哪裡，開始 T4（回收第一台、重建並停止第二台）。

## Agent 使用規則

提示起點：「讀本週任務卡，只列 T1 計畫、預測及需要我核准的精確資源，先不執行 AWS 變更。」

每次核准工具前先讀命令或差異；不使用永久自動核准或 `--auto`。遇到 AccessDenied 就停止該步並記錄；ExpiredToken 由你自己重新設定憑證。本週建議用 GitHub Copilot Agent；OpenCode 免費模型若出現 429 限流，停止重試並改用 Copilot。

## 交付

用 [報告範本](../../reports/TEMPLATE.md) 交個人增量報告：計畫與修正（含審查者）、五層時間與 early curl、(a)(b) 故障表、回收讀回、保留清單（保留哪一台、為什麼、下週誰處理）、一段用自己的話寫的請求旅程或故障解釋；`deploy/up.sh`、`deploy/down.sh` 要在 repo 裡。小組另交一頁：組內 commit、三種故障比較、每人重建秒數。

每個人都要能說出：來源 → 路由 → SG → nginx → inspection 的請求旅程。

不要提交密碼、私鑰、完整帳號 ID 或簽名網址；不要把未測寫成通過。停止 Codespace 或 End Lab 都不能代替資源回收；保留的主機必須是 stopped，並列在保留清單。

求助時附上：週次、卡片、commit、已去除敏感資訊的命令與錯誤、預期與實際、仍存在的資源 ID。費用依當期 [EC2](https://aws.amazon.com/ec2/pricing/on-demand/)、[EBS](https://aws.amazon.com/ebs/pricing/) 與 [公有 IPv4](https://aws.amazon.com/vpc/pricing/) 官方計價頁。

## 保留到下週

本週結束時，每人保留一台**已停止**的主機（第二輪）與它的 SG、key pair；其他全部回收。停止期間主機不計運算費用，但磁碟仍可能計費，依當期官方計價。下週（W4）開場啟動它：公開位址會改變，要重新核對網址與 SG 來源。主機壞了或 Lab 被重置，就用 `deploy/up.sh` 重建。
