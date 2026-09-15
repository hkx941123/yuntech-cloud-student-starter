# W2：私有物件與短效分享

目標：建立一個有自己標籤的私有 bucket，保存與更新合成文字，再精確回收。

前置：完成上一階段或由 Git／備份重建；身分驗證通過；填妥本次資源與回收清單。

方法：查 s3api create-bucket、put-public-access-block、put-object、get-object 與 s3 presign help。先畫出物件、bucket 與權限的關係；短效 URL 只在程式記憶體使用。

公開驗收：下載 bytes 相同；四項 public block=true；匿名拒絕；短效讀取成功後到期拒絕；只刪本題物件並確認 bucket 不存在。

交付：自己的程式與設定、可重現步驟、成功與拒絕／故障證據、一次修正及原因、成本與回收證據。
在 [報告模板](../../reports/TEMPLATE.md) 填入本次實際觀察；未測寫未測。
主要參考：[AWS CLI](https://docs.aws.amazon.com/cli/latest/reference/)、[Boto3](https://boto3.amazonaws.com/v1/documentation/api/latest/index.html)。
