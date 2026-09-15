# W1–W2：環境與唯讀盤點

目標：完成自己的 Codespace、隱藏憑證輸入與身分核對，說明 browser、Codespace、AWS 三者位置。

前置：完成上一階段或由 Git／備份重建；身分驗證通過；填妥本次資源與回收清單。

方法：執行 scripts/verify-aws.sh、aws-inventory.sh；先閱讀 CLI help 與 JSON query，不建立資源。

公開驗收：工具版本、遮蔽帳號的身分驗證、區域與唯讀盤點；解釋 ExpiredToken 和 AccessDenied 的差異。

交付：自己的程式與設定、可重現步驟、成功與拒絕／故障證據、一次修正及原因、成本與回收證據。
在 [報告模板](../../reports/TEMPLATE.md) 填入本次實際觀察；未測寫未測。
主要參考：[AWS CLI](https://docs.aws.amazon.com/cli/latest/reference/)、[Boto3](https://boto3.amazonaws.com/v1/documentation/api/latest/index.html)。
