# 0.16.1 / build 51 取源失敗修復

## 重現與原因

2026-11-13 在專用 iPhone Duo 模擬器，以正式 Release 介面開啟《幸得重生不負青梅》第 1 集，首次與手動重新載入皆顯示「來源未回傳影片資料，請稍後重試」。這是取得影片網址之前的 API 空回應，不是下載影片期間的 CDN 緩衝。

使用相同的 JavaScriptCore、原生 HTTP 與官方集數對照表抽測五次取源：第 1 集失敗兩次、第 20 集一次成功一次失敗、第 2 集成功。失敗時主 GET 與四次舊 POST 均 HTTP 200、body 長度 0。因此它並非固定某一集失效，也不能把 HTTP 200 當作成功。

參考 [jackotom/hongguo-drama 的 app-source.js](https://github.com/jackotom/hongguo-drama/blob/3b31058575f5c9aef0d1e2b4c98656ac95dc153c/src/native/app-source.js) 發現，本 App 已更新主 GET，但備援 POST 還使用舊的 7.1.3.32、未壓縮 JSON 與舊簽署流程。備援無法可靠接手主來源的空回應。

## 修正

- 備援 POST 對齊參考來源的 7.4.3.32 profile、gzip body 與 Argus/Ladon signer。簽章和摘要都使用真正傳送的壓縮位元組，inline 媒體使用對應的 User-Agent。
- 保留現有期限、有限次數、指定集數比對、取消，以及明確拒絕／授權錯誤停止規則。搜尋與帳號簽署維持各自 profile。
- 搜尋卡片改由搜尋頁自己的選取狀態開啟詳情，避免混合 destination/value 導航後出現空白搜尋頁；返回時保留搜尋字詞。
- 更新 JavaScript SHA-256 manifest，建置後再次比對 App 內資源。

## 已有驗證

- 更新 POST 後連續三次實際取源成功：第 20、1、2 集。第 20 集主 GET 與第一個 POST 仍回空資料，但替代主機的新版 POST 回傳完整 1080p 片源。這證明備援實際有接手，不代表來源 API 已不再偶發空回應。
- 新增原生 runtime 回歸案例，模擬主 GET 和第一個 POST 都空回應，確認第二個 POST 使用 gzip、正確摘要與指定集數，再回傳正確媒體。簽章測試確認改動實際 body 會使簽章不同。
- 核心與 AppSupport 測試通過；完整播放及 Release UI 實測結果於下方補記。

測試證據只記錄 host/path、HTTP 狀態、長度及耗時，不保存帳號、Cookies、註冊身份、簽名網址或影片金鑰。實際手機播放與模擬器證據分開報告。
