# legado.koplugin

[![License](https://img.shields.io/badge/License-CC_BY--NC_3.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc/3.0/)
[![KOReader Version](https://img.shields.io/badge/KOReader-v2024.01+-green.svg)](https://github.com/koreader/koreader)

>一个在 KOReader 中阅读 Legado 开源阅读书库的插件, 适配阅读3.0, 支持手机app和服务器版本，初衷是 Kindle 的浏览器体验不佳, 目的部分替代受限设备的浏览器实现流畅的网文阅读，提升老设备体验。

---

<p align="center">
  <img src="./assets/demo.gif" alt="demo" style="max-width:40%; height:auto;">
</p>


## 功能特性

- 前后无缝翻页浏览
- 离线缓存，自动预下载章节
- 同步阅读进度
- 服务器版换源搜索
- 碎片章节历史记录清除
- 支持漫画流式阅读
- 兼容无触摸按键设备
- 支持绑定按键或手势

---

## 安装步骤
1. 下载插件压缩包或克隆本仓库
2. 将解压后的插件文件夹（`legado.koplugin`）复制到 KOReader 的插件目录 "`koreader/plugins/`"
3. 安装后在文件管理界面顶部菜单搜索部分找到插件菜单入口
4. 设置服务接口地址 (分为服务器版和阅读app，按说明填写)
5. 可在`点击与手势`里设置快捷键 (比如在文件管理界面长按右下角开启书库，在阅读界面长按右下角返回章节目录)
- [漫画阅读优化设置](https://hanatsumi.github.io/rakuyomi/reader-recommended-settings/index.html)
- [Koreader官方指南](https://koreader.rocks/user_guide/#L1-manga)
- [文本阅读调整](https://koreader.rocks/user_guide/#L2-styletweaks)

## 设备支持  
**已验证机型**：  
・Kindle → K3/K5/PW4  
・Kobo → Libra 2  
・其他KOReader设备 → 理论兼容  

💡 提示：遇到问题请反馈 | Reader服务器版已支持多用户! | 漫画缓存注意及时清理  

-----

## 项目依赖与致谢

本插件基于以下优秀开源项目构建：

#### UI界面
- 界面组件修改自 [Rakuyomi项目](https://github.com/hanatsumi/rakuyomi)
- 核心框架依赖 [KOReader](https://github.com/koreader/koreader)

#### 数据服务
- 兼容 [阅读app](https://github.com/gedoor/legado) 接口
- 支持 [reader-server](https://github.com/hectorqin/reader) 服务端

---

### 开源声明
> 本插件不提供内容，如有侵权请联系删除