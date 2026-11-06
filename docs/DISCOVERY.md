# 選劇資料與介面

查閱日期：2026-11-07。0.3.0 將選劇集中於「劇場」，保留原生三分頁與完整直式海報，不改播放器或加入帳號功能。實際測試結果集中於 [TESTING.md](TESTING.md)。

## 資料入口

| 入口 | 資料依據 | 顯示範圍 |
| --- | --- | --- |
| 推薦 | 官網 `/category/{contentType}` | 真人劇、漫劇、AI 劇的公開熱門目錄，並非個人化推薦 |
| 排行榜 | 官網 `/rank/{route}` | 總榜、真人劇、漫劇、AI 劇；名次、熱度及評分只顯示來源提供的文字 |
| 新劇 | App 公開目錄 metadata 的 `online_time=days_7`、`sort=online_time` | 真人劇、AI 劇分開取得的近期上新；不是未來排期或全站跨類時間排序 |
| 分類 | 官網 `/category/{contentType}/{genre}` | 題材選項讀取該內容類型的 `selectorList`，不以搜尋關鍵字冒充分類 |
| 藝人 | 劇集 `celebrities` 與官網 `/character/{id}` | 姓名、頭像、角色、公開簡介和當次頁面提供的參演作品；不稱完整生涯 |
| 相似推薦 | 劇集詳情 `recommendationGroups.related_list` | 官網對該劇提供的相似片單，排除本劇並去重，不混入 `hot_list` |

推薦與分類從官網的結構化 SSR JSON 讀取。排行榜有分段傳送的 JSON literal，必須依 route 與 content key 讀取；不執行網頁提供的 JavaScript。原始官網頁面及臨時實網快照留在 `build/catalog-research-0.3.0/`，不隨程式或來源包發行。

舊專案的 `sort_type=2` 在本輪檢查中，對新分類路徑回傳 404，對舊 `/category` 入口則重導後回到 `sort_type=1`。因此沒有將該入口標成最新排序。公開目錄也沒有可可靠使用的發布時間；不把建立時間、數字狀態或作品編號推算成上架日。

## 互動

- 搜尋維持明確入口，瀏覽及切換篩選只請求劇集 metadata。
- 題材篩選先在面板選擇，套用後重新載入；切換模式或題材時隔離舊請求與分頁，避免不同條件的海報混在一起。
- 題材使用服務端真實分類。沒有將當頁的完結／更新中篩選包裝成全片庫查詢。
- 海報沿用等比完整顯示與自適應網格，點海報先看詳情，明確開始觀看才取影片來源。
- 詳情頁的演員卡可進入藝人作品頁；評分、熱度、收藏／按讚數與發布日期只在來源提供時顯示。發布日採 `first_visible_time`，不使用作品 `create_time` 替代。
- 演員與相似片單沿用同一次劇集詳情回應；選用 metadata 缺失或格式變更時不阻止已正常的分集與播放入口。
- 使用選用橋接時，僅顯示橋接協定已支援的目錄與搜尋能力。

## 上游參考

- [紅果官網分類](https://hongguoduanju.com/category/real-drama)、[紅果熱播榜](https://hongguoduanju.com/rank/hot-drama)：本輪直接核對動態題材、榜單文字、分頁與實際路徑。
- [劇集詳情樣本](https://hongguoduanju.com/detail?series_id=7701935931787316286)、[藝人公開頁樣本](https://hongguoduanju.com/character/7429227723668591897)：本輪核對演員／角色、公開參演作品、社交數據與延後回傳的相似片單。
- [jackotom 官網 adapter](https://github.com/jackotom/hongguo-drama/blob/2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0/src/native/catalog.js)、[近期上新 adapter](https://github.com/jackotom/hongguo-drama/blob/2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0/src/native/hongguo-app-new.js)：GPL 來源的路徑、欄位與有上限的匿名目錄流程參考。
- [N3urda 目錄實作](https://github.com/N3urda/hongguoTV/blob/eea73e6a45569a2cbbb9440f7cd5290c459b0b70/server/vendor/hongguo.cjs)：部分舊篩選會組成搜尋詞，不當作精確分類移植。
- [yangbin1322 發行倉庫](https://github.com/yangbin1322/hongguo-player)、[aston314 發行倉庫](https://github.com/aston314/hongguo-tv-releases)：介面與功能參考；未提供的 App 原始碼不作為 API 存在的證據。

完整許可說明見 [SOURCES.md](SOURCES.md) 與 [NativeRuntime/UPSTREAM.md](../Sources/HongguoCore/NativeRuntime/UPSTREAM.md)。
