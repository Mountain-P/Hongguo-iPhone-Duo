# 選用內容橋接服務

iPhone App 預設直接讀取公開網站；本服務只有在設定中選擇「自架橋接」時才需要。

需要 Node.js 22 或更新版本。在本目錄執行：

```sh
npm run setup
npm test
npm start
```

`npm start` 綁定 `127.0.0.1:8787`。iPhone 連同一 Wi-Fi 的 Mac 時，使用 `npm run start:lan`，再在 App 輸入啟動輸出的區網位址。`BRIDGE_TOKEN` 可設定 Bearer 存取口令；App 設定填相同口令。`PORT` 可改埠號。公開部署請在前方配置 HTTPS。

預設使用新增的 current-source provider：網站提供目錄與搜尋，現行匿名 App 註冊／取源提供相容 H.264 或 HEVC 媒體。原始固定版本 provider 保留為 `npm run start:legacy`，其舊取源已在本次實測失敗，不建議日常使用。

Docker 使用本目錄新增的設定：`docker compose up --build -d`。`server/Dockerfile` 與 `server/compose.yaml` 保留上游原檔，仍啟動舊 provider。

`npm run probe` 會依序測試 health、真實首頁、搜尋、詳情與第一段媒體；結果逐項輸出。`/health` 只驗證程序正常，內容源失效仍可能回覆 health 成功。`PROBE_QUERY` 可指定搜尋詞，`PROBE_TIMEOUT_MS` 指定每次 HTTP 請求時限。

完整 API、Docker 與測試片源說明見 [BRIDGE.md](../docs/BRIDGE.md)。來源與修改說明見 [SOURCES.md](../docs/SOURCES.md) 及 [UPSTREAM.md](UPSTREAM.md)。
