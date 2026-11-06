# 帳號與片庫（0.4.2／build 12）

## 原生手機驗證碼登入

「我的」提供原生 SwiftUI 登入介面：國碼、手機號碼、取得驗證碼、簡訊驗證碼與登入。手機號碼和驗證碼由使用者直接在 App 輸入，透過官方 HTTPS API 傳送；不經自建服務，也不要求在聊天中提供驗證碼。

使用者自行閱讀官方[使用者協議](https://reading.snssdk.com/wap-hongguo/dr-agreement-v2.html)及[隱私政策](https://reading.snssdk.com/wap-hongguo/dr-privacy-v3.html)，自行勾選後才能按「取得驗證碼」。不預先勾選，不在開啟頁面時自動發碼。重新發送有倒數，改號碼會取消舊操作並解除驗證碼綁定；關閉介面會取消操作並清除輸入的手機號碼及驗證碼。

官網登入方案已由實機確認不適用：iPhone 官網顯示下載導流頁，沒有可用登入入口。因此 0.4.1 的 App 登入不使用 WKWebView 或官網登入按鈕。來源要求上行簡訊時，只顯示本次挑戰提供的收件號碼／內容，由使用者自行發送，再明確按下繼續驗證；不代發、不輪詢猜驗證結果。其他來源拒絕或無法完成的驗證會明確顯示，不能當作登入成功。

登入以 SMS／後續驗證回覆中的一致、非零 UID 與有效會話憑據為依據。登入時註冊的匿名 App 裝置身分與 Cookie／Token 隨同一個登入會話保存；帳號同步沿用它，不重新註冊另一個身分。讀取通用的匿名使用者資訊不算登入驗證。Keychain 還原後會先檢查本地憑據／有效期限與 UID 結構，再由實際帳號 API 判斷會話是否仍有效；不將本地檢查描述為遠端驗證成功。

登入會話只存於這部 iPhone 的 Keychain；不放在 UserDefaults、片庫 JSON、來源查詢參數、播放請求或 CDN 請求。手機與驗證碼輸入不落檔。匿名影片取源保持獨立。登出先移除鑰匙圈中的登入資料，取消進行中的帳號請求，再切回本機片庫；不假造未確認的官方遠端登出接口。

## 本機與帳號片庫

- 本機片庫與各個帳號、各個播放來源分開儲存。舊版 `library.v1` 收藏與觀看紀錄可遷移，原資料保留。
- 片庫使用受 iOS 資料保護的原子 JSON 寫入，保留上一份有效快照；資料無法解析時不以空片庫覆蓋。
- 記錄最近觀看的分集、秒數、時長與觀看時間，也分別保存各集進度。單集看至 98% 只表示「本集看完」，不宣稱整劇看完。
- 收藏與觀看變更先存本機，按劇集合併待同步操作。只有官方確認請求成功，且本機操作編號仍相同後才移除；較舊回覆不能清掉較新的操作。操作編號由本機管理，不宣稱官方提供冪等鍵。
- 登入不自動合併訪客資料；使用者可在帳號片庫選擇「匯入本機片庫」，確認後將收藏及觀看紀錄加入帳號的待同步隊列，本機原片庫仍保留。
- 觀看紀錄的移除／清除是本機隱藏，保留防止舊雲端快照復活的記號；沒有假造官方刪除歷史接口。取消收藏則是明確的帳號待同步操作。

帳號同步先檢查會話的 UID 與有效期限，再取得雲端片庫、合併並上傳待同步變更。新的雲端觀看時間可以取代較舊本機進度；只有確認完整的收藏清單才以缺席判定遠端移除。頁數或來源覆蓋不足會保留既有資料。切換帳號、來源或登出會取消請求；先前播放器仍只能把最後進度存回原本的片庫。

## 大型片庫的載入

0.4.2 先提交已取得的觀看紀錄，再提交收藏，讓清單能先出現。缺少的劇名、海報與分集資料在背景以最多四筆並行補齊，每輪最多 50 部、總期限 45 秒；不讓逐筆詳情請求阻塞整份片庫。尚缺資料會明確標示載入中，可於下次同步繼續補齊。

補資料只改既有項目的作品資訊，不改收藏狀態、進度、時間或待同步操作編號。每輪最多上傳 20 筆收藏及 10 筆觀看變更，其餘保留排隊；沒有錯誤時才安排下一輪。片庫 JSON 上限 32 MiB，超限會顯示錯誤並保留原檔。

## 官方資料契約

帳號請求限定 `https://api5-normal-lq.fqnovel.com`，沿用原生登入的 App 7.3.5.32 profile、裝置身分、Cookie 與 `X-Tt-Token`；註冊時不帶帳號憑據。沒有切換主機、繞過來源驗證或重新登入的隱藏回退。

| 用途 | 方法與路徑 |
| --- | --- |
| 發送手機驗證碼 | POST `/passport/mobile/send_code/v1/` |
| 手機驗證碼登入 | POST `/passport/mobile/sms_login/` |
| 上行簡訊後驗證 | POST `/passport/upsms/verify/` |
| 讀觀看紀錄 | GET `/reading/bookapi/read_history/list/v` |
| 讀收藏 | GET `/reading/bookapi/bookshelf/video/list/v` |
| 收藏／取消收藏 | POST `/reading/bookapi/bookshelf/video/update/v` |
| 寫觀看紀錄 | POST `/reading/bookapi/read_history/update/v` |
| 寫續播位置 | POST `/reading/bookapi/read_progress/upload/v` |

進度由 App 的秒數換算為接口要求的毫秒。兩個進度寫入均確認成功才完成待同步操作；只成功第一個時會保留待同步狀態及明確錯誤。模糊失敗不暗中重送同一操作；使用者按「立即同步／重試」後可明確重試。來源拒絕、格式改變或登入失效會在「我的」顯示，資料仍保留於手機。

**驗證界線：** 已在實體 iPhone 完成當次原生手機驗證碼登入、更新後會話還原、片庫讀取，以及收藏新增／取消、實際播放後進度寫入的成功狀態。尚未在另一部裝置的官方 App 獨立核對進度；簽章向量與合成測試也不代替其他真人帳號或地區的驗證。來源能否接受特定地區手機號碼，由實際回覆決定，不因輸入地區列表存在就宣稱一定能收到簡訊。實機與測試結果集中記錄於 [TESTING.md](TESTING.md)。

## 來源

- GPL 官網登入與 Cookie／Profile 驗證參考：[jackotom main.js](https://github.com/jackotom/hongguo-drama/blob/2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0/main.js#L4342-L4379)、[account-session.js](https://github.com/jackotom/hongguo-drama/blob/2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0/src/native/account-session.js)。該版觀看紀錄解析最多 50 筆，不能將它描述為完整雙向同步。
- 接口形狀與單位比對：[aston314 cloud.go](https://github.com/aston314/hongguo-tv/blob/36508246eeca2cf5ef1f29f7f17f8e985d50ae2e/core/cmd/hongguotv/cloud.go#L304-L413) 與本地使用者提供／授權的 Quest 參考專案。已透過 GitHub blob SHA 確認該 `cloud.go` 與本地檔案相同，未僅依播放範圍的 `UPSTREAM-SOURCE.json` 推論。只參照通訊契約，未複製 Go 簽章實作；該 App 會話使用不同主機與版本，不能據此保證 Web 會話相容。
- 發行資訊：[hongguo-tv-releases](https://github.com/aston314/hongguo-tv-releases)、[hongguo-player](https://github.com/yangbin1322/hongguo-player)。功能敘述不能取代實際 API 或真人帳號驗證。
