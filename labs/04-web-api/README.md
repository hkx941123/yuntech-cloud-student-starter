# W4 Sprint：第一筆事件可送入、查詢並顯示

## 這週要做什麼

W3 的服務只會回答「我還活著」。這週讓它能**收一筆巡檢事件、查得到、在網頁上看得到**，而且：

- 只有持有正確權杖、角色也對的人能送或能查；
- 格式不對的事件被拒絕，並說清楚哪一欄錯。

本週事件只存在服務的記憶體裡，服務重開就不見；這是刻意的，W5 會處理。

## 先懂這些名詞

| 名詞 | 一句話 |
|---|---|
| Stop／Start | Stop 是關機保留磁碟；Start 時會拿到**新的**公開位址（本課不用固定位址 EIP，每次 Start 後重新查） |
| 控制通道（control plane） | 對 AWS 下指令（開關、查詢主機），看你的 AWS 憑證，不經過 SG |
| 資料通道（data plane） | 直接連主機上的服務（HTTP、SSH），要過路由、SG、服務 |
| 腳本部署 | 用腳本把**某一個 commit** 裝到主機上；不手動進主機改檔案 |
| HTTP 方法（method）、路徑（path） | 要做什麼（GET 讀、POST 新增）、對哪個東西（`/events`） |
| 標頭（header）、本文（body） | 描述這次請求的欄位；要送的資料（一筆 JSON 事件） |
| 認證（authentication）、權杖（token） | 確認你是誰（失敗 401）；只有持有者知道的字串，放在 `Authorization: Bearer <權杖>` |
| 授權（authorization）、角色（role） | 決定你能做什麼（不允許 403）；reporter 只能送、operator 只能查 |
| 輸入驗證（validation） | 依契約逐欄檢查，不合就拒絕（400） |
| 秘密檔（secret file） | 只有系統管理者讀得到（權限 600）的設定檔，不進 Git、不進 user data |

## 一次事件請求怎麼走

```text
Codespace ─▶ SG(80, /32) ─▶ nginx:80 ─▶ inspection:127.0.0.1:8080
                                             認證(401) → 授權(403) → 驗證(400) → 重複(409) → 建立(201)
```

## 哪些已經做好、哪些你要做

**已經做好，不用改：**

- `deploy/make_user_data.py`（把程式打包成安裝腳本的工具）這週多做兩件事：
  1. 服務啟動時會讀主機上的 `/etc/inspection/app.env`。你的兩個權杖放在這個檔裡，服務才分得出誰是 reporter、誰是 operator。
  2. 安裝腳本在**已經在跑的主機**上再跑一次也會生效（最後會重啟服務）。所以 `deploy.sh` 可以直接拿它更新同一台主機，不必開新主機。
- 下方的事件契約與拒絕矩陣：規則已經定好，照著做。

**你要做：**

| 做什麼 | 放哪裡 |
|---|---|
| 送出、查詢事件的端點，以及顯示頁 | `app/service.py`（仍是這一個檔） |
| 3 筆測資：1 筆成功、2 筆該被拒絕 | `tests/fixtures/` |
| 部署腳本 | `deploy/deploy.sh` |
| 拒絕矩陣腳本（7 列一次跑完） | `tests/` 底下，檔名自訂 |

## 任務卡

| 卡 | 做什麼 | 完成證據 |
|---|---|---|
| T1 恢復 | 上課一開始就 Start 上週的主機；查新的公開位址；核對 Codespace 出口 `/32`（變了就列舊／新、經審查者核准再改）；`/health` 回 200、version 與上週相同 | 舊／新位址、`/health` 回應 |
| T2 實作 | 每人依下方契約寫 1 筆成功、2 筆拒絕的測資（`tests/fixtures/`）；請 Copilot 實作端點與顯示頁並寫離線測試；用審查清單看過再 commit | 測資、離線測試通過、審查紀錄 |
| T3 部署與拒絕 | 產生兩個權杖；請 Copilot 寫 `deploy.sh`；部署到同一台主機；跑拒絕矩陣 7 列；看一次顯示頁 | 矩陣結果、顯示頁截圖（不含權杖） |

## 事件契約

事件本文是一個 JSON 物件，只能有下列欄位：

| 欄位 | 必填 | 規則 |
|---|---|---|
| `event_id` | 是 | 1–64 字元，英數與 `-` `_`；由送出端產生，重送同一筆時不能換。本課用 `<組名>-<組內代號>-<流水號>`，例如 `g03-m2-0001` |
| `device_id` | 是 | 1–32 字元，規則同上。例如 `g03-d01` |
| `observed_at` | 是 | ISO 8601，**必須帶時區**，例如 `2026-09-29T10:00:00+08:00` |
| `type` | 是 | `status`、`anomaly`、`test` 三選一 |
| `note` | 否 | 字串，最多 200 字元；可以不給，但給了就必須是字串（`null` 也拒絕） |

不要用學號或姓名：測資會進 Git，W5 起事件會進全組共用的資料庫。截圖裡看到自己的組內代號，就知道是你送的；TronClass 會記錄是誰上傳。

服務收下時自己加上 `received_at`（UTC）。有多餘欄位、`Content-Type` 不是 `application/json`、本文超過 4 KiB，一律 400。

| 方法與路徑 | 誰能用 | 成功 | 失敗 |
|---|---|---|---|
| `GET /health` | 任何人 | 200，另外回報 `auth_configured` | — |
| `POST /events` | reporter | 201 | 401、403、400、409 |
| `GET /events` | operator | 200，最新 50 筆 | 401、403 |
| `GET /events/{event_id}` | operator | 200 | 401、403、404 |
| `GET /` | 任何人 | 顯示頁：貼上 operator 權杖後讀取清單 | — |

錯誤回應：`{"error": "<原因>", "field": "<哪一欄>"}`；**不回顯權杖、不印出整份本文**。顯示頁用 `textContent` 放事件內容，權杖只放在頁面變數，不寫進網址或瀏覽器儲存。

### 拒絕矩陣（T3，請 Copilot 寫成一支小腳本一次跑完）

| # | 請求 | 預期 |
|---|---|---|
| 1 | reporter 送一筆合法事件 | 201 |
| 2 | 同上，不帶權杖 | 401 |
| 3 | operator 權杖送事件 | 403 |
| 4 | reporter，`observed_at` 沒有時區 | 400 |
| 5 | reporter，再送一次 #1 | 409（W5 會改） |
| 6 | reporter 權杖讀清單 | 403 |
| 7 | operator 權杖讀清單 | 200，含 #1 |

## 權杖與 `deploy.sh`

```bash
umask 077
python3 - <<'PY' > .local/app.env
import secrets
print("REPORTER_TOKEN=" + secrets.token_urlsafe(32))
print("OPERATOR_TOKEN=" + secrets.token_urlsafe(32))
PY
chmod 600 .local/app.env
stat -c '%a' .local/app.env    # 一定要是 600 才能部署
```

不要 `cat` 這個檔、不要 `echo` 權杖、不要讓 Agent 把內容顯示出來（腳本可以讀它，但不能印出來）。

`deploy/deploy.sh` 規格（四條）：

1. 只部署**已 commit** 的版本：用打包器產生安裝腳本（和 `up.sh` 用的是同一份）。
2. 經 SSH 在**原本那台主機**上執行安裝腳本（Start 後公開位址變了，SSH 用 `-o StrictHostKeyChecking=accept-new` 記住新位址的指紋；不要用 `no`），再把 `.local/app.env` 經 SSH 的標準輸入放到 `/etc/inspection/app.env`（root、600），**然後再重啟一次 inspection**，服務才會讀到新的秘密。部署前先檢查本機的 `.local/app.env` 是 600，不是就停下來。秘密不進 user data、不進 Git、不出現在命令列參數或輸出。
3. 結束時確認 `/health` 的 version 等於這次的 commit、`auth_configured` 是 true。
4. 執行前印出目標主機與 commit，等你確認；腳本要 commit。

主機壞了才用 `up.sh` 重建，平常更新都用 `deploy.sh`。

## 審查 Copilot 的程式：四件事

Copilot 寫的程式通常能跑，但常漏掉下面這些。commit 前逐條看；沒過就請它改，並記下是哪一條。

| 看什麼 | 為什麼 | 怎麼看 |
|---|---|---|
| 1. 先確認是誰，才看內容：順序是 401 → 403 → 400 → 409 → 201 | 沒有權杖的人，不該從錯誤訊息學到欄位規則；他送什麼都只該拿到 401 | 不帶權杖、送一筆格式錯的事件：要回 401，不是 400 |
| 2. 權杖和整筆事件不寫進日誌、不放進錯誤回應 | 日誌很多人看得到、也留很久；權杖外流，別人就能冒用你送事件 | 在程式裡找 `print`、`logging`，看印了什麼；錯誤回應只有 `error` 和 `field` 兩欄 |
| 3. 顯示頁用 `textContent` 放事件內容；權杖不放網址、不存進瀏覽器 | `note` 是別人送來的文字，用 `innerHTML` 放會被當成網頁程式執行；網址會留在瀏覽紀錄和 nginx 日誌 | 在程式裡找 `innerHTML`、`localStorage`、`?token=`，都不該出現 |
| 4. 你的 3 筆測資真的有被測試讀進去 | Copilot 可能寫出沒讀你檔案的測試，全部通過也不代表檢查過 | 故意把成功那筆改壞，測試應該失敗；確認後改回來 |

## 常見狀況

- **Start 後舊網址逾時**：正常，位址換了。用 AWS CLI 查新位址（控制通道不受影響）。
- **所有請求都 401**：先看標頭是不是 `Authorization: Bearer <權杖>`，再確認 `deploy.sh` 有放秘密檔；不要把權杖印出來比對。
- **筆電瀏覽器打不開顯示頁**：同 W3，用 private forwarded port。權杖由你本人貼進頁面，不要交給 Agent。
- **拒絕矩陣腳本送錯主機**：腳本送出前先查一次主機現在的公開位址，不要沿用上週記下的位址。


## 交付（TronClass）

照 [繳交範本](../../reports/W04_繳交範本.md) 填寫，範本第一段寫了怎麼複製、怎麼下載。

- **個人**：上傳填好的 `.md` 和一張顯示頁截圖。內容是 `/health`、拒絕矩陣 7 列、一段自己的話。