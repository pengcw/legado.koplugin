# legado.koplugin

[![License](https://img.shields.io/badge/License-CC_BY--NC_3.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc/3.0/)
[![KOReader Version](https://img.shields.io/badge/KOReader-v2024.01+-green.svg)](https://github.com/koreader/koreader)

>一个在 KOReader 中阅读 Legado 开源阅读书库的插件, 适配阅读3.0, 支持手机app和服务器版本，初衷是 Kindle 的浏览器体验不佳, 目的部分替代受限设备的浏览器实现流畅的网文阅读，提升老设备体验。

---

<p align="center">
  <img src="./assets/demo.gif" alt="demo" style="max-width:40%; height:auto;">
</p>


## 功能特性

- 前后章节无缝翻页浏览
- 离线缓存，自动预下载章节
- 同步阅读进度
- 书籍换源搜索
- 碎片章节历史记录清除
- 支持漫画流式阅读
- 支持绑定按键或手势
- 文件浏览器快捷方式

---

## 安装方法

1.  下载最新版本的插件发布包 [release](https://github.com/pengcw/legado.koplugin/releases/)。
2.  将 `plugins/legado.koplugin` 目录复制到设备上 KOReader 的插件目录 `koreader/plugins` 文件夹中。
3. 重启 KOReader。
4. 安装后在 `文件管理界面` 顶部菜单搜索部分找到插件菜单入口。
4. 设置服务接口地址 (分为服务器版和阅读app，按说明格式填写)。
5. (可选) 在 `点击与手势 > 手势管理器` 里设置快捷键 (比如在文件管理界面长按右下角开启书库，在阅读界面长按右下角返回章节目录)。


## 设备支持  
**已验证机型**：

・Kobo → Libra 2   
・Kindle → K3/K5/PW4   
・其他 KOReader 设备 → 理论兼容


## 常见问题排查
<details>
<summary>——————Q&A——————</summary>

<details>
<summary> 验证插件是否安装成功</summary>

---
- koreader 顶部下拉菜单 `工具 > 更多工具 > 插件管理器` 里面查看是否有 `Legado 阅读书库`，有就是安装成功了。
</details>

<details>
<summary>安装后找不到插件入口</summary>

---
1. 首先检查插件是否安装成功
2. 确保你处于 `文件浏览器` 界面
3. 打开顶部菜单🔍 `搜索` 
4. 找到 `Legado 书目`
</details>

<details>
<summary>填写接口后提示 timeout 或下拉无法刷新书架</summary>

---
**问题描述**：  
设置好接口后刷新加载不出书架，出现 timeout 或其他提示（通常是接口无法正确访问）。  
   注意：这属于网络连接问题，非插件本身问题，请按以下步骤排查：

---
#### 排查步骤：

1. **检查接口地址准确性**  
   - IP 地址输错的情况时有发生
   - 示例正确格式：`http://192.168.1.8:1122`

2. **验证接口格式**  
   - 开源阅读 app：**不需要**加 `/reader3` 后缀  
   - 服务器版本：**需要**加 `/reader3`  
   - 服务器版若有账号密码认证需按格式填入

3. **测试接口可访问性**  
   - 假设接口地址为：`http://192.168.1.8:1122`  
   - 在 Kindle 浏览器访问（或同局域网其他设备）：  
     ```url
     http://192.168.1.8:1122/test
     ```
   - ✅ 正常：页面会显示 `test` 字符  
   - ❌ 异常：无输出或其他 

---

### 常见失败原因
- 阅读 APP 的 Web 服务未开启  
- 地址或端口号输入错误  
- 设备不在同一局域网  
- 局域网开启了网络隔离  
- （根据实际情况排查其他可能原因）

---
</details>

<details>
<summary>安装后点击章节报错或者闪退</summary>
   
   ---
   - 一般是 koreader 版本低了有部分函数不兼容, 请升级最新版
</details>

<details>
<summary>如何同步阅读进度</summary>

---
 - 在目录页面有菜单 `拉取网络进度` 与 `上传章节` （为节约资源，插件没有在阅读时自动同步进度，需要手动点击）
</details>

<details>
<summary>其他端换源了与本地内容不一致</summary>

---
- 刷新书架即可
</details>

<details>
<summary>如何清除缓存</summary>

---

#### 1. 单章缓存清除
***入口***：按住章节不放有菜单选项

#### 2. 单本书籍缓存清除
***入口***：章节页面左上角菜单选项

#### 3. 所有缓存清除
两种方法（效果相同）：
- 书架页面左上角菜单有选项
- KOReader 菜单 `开发者选项 > 清除缓存`

</details>

<details>
<summary>源章节内容和本地不一致</summary>

---
- 在章节菜单长按章节清除缓存后重新下载
</details>

<details>
<summary>开源阅读是否需要一直开着 web 服务</summary>

---
- 章节缓存后支持离线阅读
</details>

<details>
<summary>保活开源阅读 app 后台的办法</summary>

---
- 如果出现频繁 web 服务被关闭，可以保活下后台，每个品牌不一样，可以参考下 `adguard` 的设置，关键词 `“如何让 AdGuard 保持后台运行”`, 把程序改成开源阅读即可。
</details>

<details>
<summary>开源阅读 app 接口地址频繁变化</summary>

---

> 这个属于网络知识固定 ip 的方法：

🔸 **手动设置 DHCP**  
🔸 **路由器里面绑定 MAC**  
🔸 **关掉手机 wifi 设置里面手机虚拟 mac 地址**  
（每个手机品牌不一样，大概差不多这个意思）

</details>
</details>

## 项目依赖与致谢

本插件基于以下优秀开源项目构建：

#### UI界面
- 界面组件修改自 [Rakuyomi项目](https://github.com/hanatsumi/rakuyomi)
- 核心框架依赖 [KOReader](https://github.com/koreader/koreader)

#### 数据服务
- 兼容 [开源阅读app](https://github.com/gedoor/legado) 接口
- 支持 [reader-server](https://github.com/hectorqin/reader) 服务端

---

### 开源声明
> 本插件不提供内容，如有侵权请联系删除