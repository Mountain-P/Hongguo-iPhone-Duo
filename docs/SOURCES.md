# 參考專案與許可

查閱日期：2026-11-07。這份文件記錄本專案使用的參考來源；平台影片與片名、海報的權利仍屬各自權利人。

## N3urda/hongguoTV

- 原始碼：https://github.com/N3urda/hongguoTV
- 固定提交：`eea73e6a45569a2cbbb9440f7cd5290c459b0b70`
- 許可：GPL-3.0-only。
- 本專案選用橋接來源：`server/`、`tests/server.test.mjs`、根目錄 `LICENSE`。
- 完整保留 `server/vendor/NOTICE.md`、`LICENSE.drpys`、`LICENSE.template-tv` 及原檔案註解；vendor 演算法的原始來源與提交記於該 NOTICE。
- 本地新增啟動、探針、合成影片 fixture 與文件；lockfile 的 Tencent npm mirror URLs 改為官方 npm registry，固定版本與 integrity 未改。

橋接是獨立選用 Node 服務，原始碼隨專案完整提供。0.2.0 的 iPhone 內建路徑重用有 GPL 來源的簽章 JS，並以原生 URLSession／CommonCrypto／JavaScriptCore 替代 Node API；不將 Node、Electron 或 Android runtime 放進 iPhone App。MP4／CENC 的 Swift 移植保留相同演算法來源與 GPL 聲明。

## yangbin1322/hongguo-player

- 專案：https://github.com/yangbin1322/hongguo-player
- README 說明這是發行用途倉庫，未提供原始碼；根目錄只有 `.github`、`README.md` 與 `docs`，未提供 LICENSE。
- 僅作為搜尋、劇集列表與播放器流程的功能參考，沒有複製此專案的程式碼或發行檔。

## jackotom/hongguo-drama

- 原始碼：https://github.com/jackotom/hongguo-drama
- 查閱提交：`2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0`
- 許可：GPL-3.0。
- 參考 `src/native/catalog.js`、`hongguo.js`、`hongguo-search.js` 的公開網站路徑、回應欄位及播放器綁定檢查。0.3.0 另參考 `hongguo-app-new.js` 的匿名近期上新請求、游標與顯示文字；選劇能力與舊介面限制記於 [DISCOVERY.md](DISCOVERY.md)。
- 0.4.0 曾研究 `main.js`、`account-web-login.js`、`account-session.js` 的官網登入／Cookie 方案；iPhone 實機顯示導流頁而無登入入口，0.4.1 已移除 WK 登入畫面，改用原生手機驗證碼 API。既有 GPL 簽章與匿名註冊可重用，帳號新增方法／路徑保持窄白名單，不改匿名播放 profile。登入、同步契約與真人驗證界線見 [ACCOUNT.md](ACCOUNT.md)。
- 原生 iPhone 介面與服務層另以 Swift 實作；本專案保留相容 GPL 許可及此來源聲明。
- 選用 Node bridge 的 `server/modern/` 保留來源 NOTICE／GPL 全文。`download-quality.js`、`sm3.js` 未改；`app-source.js`、`playback-device.js` 加入取消、獨立 GET 身分與有上限的 POST 回復；本地新增 `playback-recovery.js`、`stream-cache.js`。來源與差異詳見 `Backend/server/modern/UPSTREAM.md`。原 N3urda provider 未改；共用 HTTP 層加入請求取消傳遞。
- 匿名註冊協定的轉引來源為 tsukiyo-zero/hongguoTV 提交 `388931852ddc614db8b00775a3dc54c5ede6307f`，其檔案亦署名 charlie901208/HGTV，均為 GPL-3.0-only。完整說明見 `Backend/server/modern/licenses/NOTICE.txt`。
- 舊 DirectWebService 保留網站公開分集與 protectedPlayback 的判定。預設 NativeCatalogService 取得完整 `vid_list` 後向內建取源流程請求，保留來源當次明確拒絕，不以網頁預覽集數作 App 上限。

## aston314/hongguo-tv 協定參考

- 實際原始碼：https://github.com/aston314/hongguo-tv
- 查閱提交：`36508246eeca2cf5ef1f29f7f17f8e985d50ae2e`（v0.2.150）。
- 取源說明：`docs/playback-identity-recovery.md`，查閱版本 `6ff2f966cf18c31c8e36acf1d72a173a2c93f2bb`。
- 用於核對 GET 優先、POST 的身分重建／主機順序／次數上限、獨立播放 profile 與固定簽章向量。
- 0.4.1 另核對原生手機登入／上行簡訊驗證與 `cloud.go` 的收藏／歷史／進度接口形狀及毫秒單位；GitHub blob SHA `cf66a0ffa9d20750458ec3ea84c4dc2a2c265c17` 與使用者提供的本地 Quest 參考相同。沿用登入的 App 身分與 LQ 7.3.5.32 profile；國際 mode 4 依通訊事實獨立以 JS 表達並與合成向量比對，未複製 Go 簽章程式，亦未據此宣稱境外手機一定能收碼。
- 可用參考子集未見 LICENSE；不宣稱該 Go 原始碼為 GPL，沒有複製其 Go 演算法實作。實際隨 App 分發的程式來自上述已有 GPL 聲明的 JS 及本專案 Swift 實作。

## aston314/hongguo-tv-releases

- 發行倉庫：https://github.com/aston314/hongguo-tv-releases
- 查閱 tree：`45cd81b3d4bfe8172baf5c05ac1261424aaed34d`
- 內容：發行說明、更新 JSON、截圖、Issue 範本；未提供 App 原始碼與 LICENSE。
- 僅參考搜尋、追劇、分集及跨裝置播放等產品方向，沒有複製或反編譯發行二進位。

## 原生系統元件

SwiftUI、AVFoundation、AVKit、Foundation、CoreGraphics、ImageIO、Security、JavaScriptCore、CommonCrypto、CryptoKit 及系統 zlib 由 Apple SDK／系統提供。0.7.0 的海報縮圖使用系統 ImageIO，沒有新增第三方圖片套件；本機播放 runtime 的 `app-source.js` 新增省流量選源政策，保留既有簽章與授權聲明。內建 Buffer 相依為 MIT 的 buffer 6.0.3、base64-js 1.5.1，以及 BSD-3-Clause 的 ieee754 1.2.1，各原始 LICENSE 隨 Core assets 分發。精確來源、SHA256 與替代 Node API 的差異見 [NativeRuntime/UPSTREAM.md](../Sources/HongguoCore/NativeRuntime/UPSTREAM.md)。

Xcode／iOS 使用條款依 Apple 規定。測試 fixture 由本專案程式產生，不含平台影片。App 不附劇集媒體、登入 Cookie 或固定裝置憑證。
