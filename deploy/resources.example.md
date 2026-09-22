# W3 個人資源清單（填寫範本，每人一份）

帳號末四碼：___；region：___；組名：___；組內代號：___；部署 commit：___。
既有預設 VPC／子網／IGW 僅引用，不能刪除。

| 資源類型 | 本次建立的 ID | UTC 建立時間 | 擁有權標籤／關聯證據 | 精確回收方式 | 回收後讀回與時間 |
|---|---|---|---|---|---|
| EC2 instance | 待填 | | | 以 ID terminate | |
| 根 EBS | 待填 | | instance 關聯、DeleteOnTermination | 隨終止刪除，仍需讀回 | |
| ENI | 待填 | | instance 關聯 | 隨終止刪除，仍需讀回 | |
| Security group | 待填 | | course/week/group | 確認 ENI 已清除後，以 ID 刪除 | |
| 匯入的 EC2 key pair | 待填 | | 自己生成的公鑰對應 | 以 ID 刪除 | |
| SSM instance-profile 關聯（若測） | 待填 | | 既有 LabInstanceProfile | 解除本次關聯，不刪 profile | |

重建時另記第二輪的新 ID，不能以名稱當作刪除條件。第二輪主機本週結束時停止保留，在「回收後讀回與時間」欄改寫「保留（stopped），下週 W4 處理」。報告不附完整帳號、憑證、私鑰或簽名網址。
