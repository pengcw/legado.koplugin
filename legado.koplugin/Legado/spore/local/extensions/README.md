# 扩展书源

本目录存放基于标准 Legado BookSource JSON 的内置评论适配规则。

目前支持：大灰狼、光遇、晴天、书山聚合。

- 使用 `ruleContent.content` 获取评论并生成 HTML。
- `review_ext.lua` 根据原书源标识选择对应 JSON。
- `bookSourceUrl` 中的 `.invalid` 仅为占位符，运行时替换为实际页面来源。
- 新增适配：添加 JSON，并在 `review_ext.lua` 中注册对应关系。

扩展请求不继承原书源的登录状态。
