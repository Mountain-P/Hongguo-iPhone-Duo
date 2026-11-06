# 選用橋接與本機整合測試

App 使用「自架橋接」播放 App 片源時，需要執行以下服務。官網公開內容瀏覽不代表完整 App 片源可播放。HTTP 層源自固定版本 N3urda/hongguoTV，加入客戶端中斷取消；預設 provider 另接 jackotom/hongguo-drama 的匿名註冊與 App 取源。

## 啟動

```sh
cd Backend
npm run setup
npm test
npm start
```

同區網 iPhone 連線：執行 `npm run start:lan` 並在 App 設定輸入 `http://Mac區網IP:8787`。App 首次連線時允許「區域網路」。設定存取口令時，讓服務的 `BRIDGE_TOKEN` 與 App「口令」相同。HTTPS 服務可直接輸入完整 HTTPS 網址。

Docker 使用 Backend 根目錄的新增設定，啟動現行 provider：

```sh
cd Backend
docker compose up --build -d
```

Docker 服務使用唯讀檔案系統、非 root 使用者、移除 capabilities。Docker 的 healthcheck 驗證程序與設定的口令，不代表平台來源可用。本次工作環境未安裝 Docker，未執行容器建置。

原 `server/Dockerfile`、`server/compose.yaml` 及 `provider.mjs` 保留上游原檔，啟動舊 provider；舊 provider 在本次測試中可讀取首頁／詳情，但搜尋與媒體曾回覆 502。預設 `npm start` 及根目錄 Docker 已改用現行 provider。

## API 契約

若設定口令，所有請求包含 `Authorization: Bearer <口令>`，包含 health 與媒體請求。

| 路徑 | 回傳 |
| --- | --- |
| `GET /health` | `{service:"hongguotv",version:"0.1.0",apiVersion:1,upstream:"unverified"}` |
| `GET /api/home?page=1` | `{items:[Card],page:1}` |
| `GET /api/search?q=劇名&page=1` | `{items:[Card],page:1}` |
| `GET /api/series/{seriesId}` | `Card` 加 `episodes:[{id,title,number}]` |
| `GET /api/episodes/{episodeId}/play` | `{path:"/api/episodes/{episodeId}/stream",contentType:"video/mp4"}` |
| `GET/HEAD /api/episodes/{episodeId}/stream` | MP4，支援單一 `Range: bytes=start-end`、後綴範圍與 416 回應 |

`Card` 欄位為 `{id,title,cover,description,badge,tags}`。分頁 1–100；搜尋詞 1–80 字。`/play?fresh=1` 會清除該集取源快取。影片最多四路同時串流。平台錯誤以 502 JSON 回應，不會將含簽章的片源網址寫入回應或日誌。

劇集詳情使用官方完整 `vid_list`，並在記憶體保留 video ID 對應的劇集與 `content_type`。公開網站的 `accessible_episode_cnt` 不作為 App 片源的可播集數判斷。

每次取源先使用獨立匿名身分呼叫 `video_tab` GET；該身分只保留允許的匿名註冊 Cookie，不讀取帳號 Cookie。GET 未取得可用模型時，才進入最多兩輪 POST 復原：每輪重新匿名註冊，依序嘗試 sinfonlineb、hl 兩個 host，合計最多四次。每次以原始 JSON 位元組、當次 query 與時間重新簽署六個 header；播放版本 7.1.3.32 與帳號／搜尋版本分開。整次模型取源限時 30 秒，明確授權拒絕、業務拒絕、安全攔截或不支援的編碼會停止；不呼叫獎勵、解鎖或購買接口。

客戶端在回應完成前斷線會取消其等待。多個客戶端共用同一集準備工作時，只有最後一個等待者取消才中止上游；已準備好的媒體快取不綁定先前 `/play` 請求，每個 Range 使用本次請求的取消訊號。H.264／HEVC 篩選與 CENC Range 解密保留。

## 真實來源檢查

服務啟動後在另一終端執行 `npm run probe`。檢查依序為 health、首頁、搜尋、詳情、第一集的前 32 bytes。若要測試指定服務／劇集，使用 `BRIDGE_URL`、`PROBE_QUERY`、`PROBE_SERIES_ID` 環境變數；口令從 `BRIDGE_TOKEN` 取得。

探針的媒體檢查僅確認 206、32 bytes 及 MP4 `ftyp`，不代表整集下載、解碼、聲音或長時間播放通過。來源服務可能調整接口、限制存取或只提供預覽；health 成功不能解讀為內容可用。

2026-11-06 初次 provider 整合的實測：health、24 部首頁、10 筆搜尋、102 集詳情與 32-byte 媒體 Range 全部通過；另讀取同一集前 1 MiB，FFmpeg 成功解碼前兩秒 50 幀 HEVC 1080×1920 影片及 AAC 音訊。接著在 30 MB 上限內取得完整同一集（15,237,858 bytes、2:54.20），完整音訊／影片解碼 exit 0、無解碼錯誤。搜尋首次曾遇上游 5xx，provider 對 5xx／連線暫時錯誤最多重試一次，明確拒絕不反覆重試。

同日加入上述 GET→POST 復原後另做有上限的實測：24 部首頁、102 集官方詳情成功；指定集前 1 MiB 回傳 206、正確 Content-Range（總長 4,682,330 bytes），解密後 FFmpeg 前兩秒解碼 exit 0。該集模型診斷為 HEVC／1080p，GET 未取得可用模型，第一輪第一個新匿名身分 POST 成功（模型請求約 1.17 秒）。此輪未下載完整一集或整部劇。22 項離線／本機 HTTP 測試涵蓋簽章固定向量、精確 JSON 位元組、身分隔離、四次重試上限、明確拒絕、取消及兩個客戶端共用工作。

這些是本機伺服器／解碼驗證，並非實體 iPhone 安裝、人工聽音或原生 AVPlayer 播放驗收；真實片源為 HEVC，未另測真實 H.264 劇集。

## 不連平台的本機測試片源

```sh
cd Backend
npm run fixture
```

這會在 macOS 使用 Command Line Tools 與 AVFoundation 產生四秒、320×568、H.264、無聲的合成 MP4，再於 `http://127.0.0.1:8788` 提供固定的三集測試資料。App 選「自架橋接」後填入該網址；實機請設定 `BRIDGE_HOST=0.0.0.0` 並使用 Mac 區網 IP。畫面劇名與簡介明確標示測試資料。

可執行 `BRIDGE_URL=http://127.0.0.1:8788 npm run probe` 驗證完整 API 流程。這項測試不代表任何紅果真實劇集可用。產生的 `fixtures/sample.mp4` 可刪除並重新產生，未納入原始碼版本追蹤。

## 來源檔案與許可

上游提交、原始許可與本地修改見 [SOURCES.md](SOURCES.md)、[Backend/UPSTREAM.md](../Backend/UPSTREAM.md)、[現行片源來源記錄](../Backend/server/modern/UPSTREAM.md)。原 provider、媒體 primitives 與上游測試保留；HTTP 層僅加入取消訊號傳遞。`server/package-lock.json` 將失效的 Tencent npm tarball mirror 改為官方 npm registry，版本和 integrity 保持固定。
