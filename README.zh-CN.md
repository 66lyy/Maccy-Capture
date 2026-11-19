# Maccy Capture

[English](README.md) | **简体中文**

这是基于 **[p0deje/Maccy](https://github.com/p0deje/Maccy)** 二次开发的**非官方修改版**，
保留原项目的剪贴板历史功能，并加入区域截图、全屏截图、贴图、
滚轮与触控板缩放、本地图片标注和语言设置。修改版使用独立应用标识，禁用官方自动更新。
截图和标注内容仅在本机处理，不调用云端识别或训练服务。

## 下载与构建

提交到 `master` / `main` 后，GitHub Actions 自动运行合成图片回归测试，并构建
Apple Silicon + Intel 通用架构的 Release `.app`，提供 ZIP、DMG 和 SHA-256 校验文件。
默认分支构建成功后，在仓库的 **Releases → Latest test build**（`capture-latest`）下载，
也可以在 **Actions → Build Maccy Capture → 成功的运行 → Artifacts** 下载；
在该工作流页点击 **Run workflow** 可手动打包。
在默认分支上手动构建也会更新测试版 Release；其他分支、版本标签和 Pull Request 只提供 Artifacts。

自动构建产物使用 ad-hoc 签名，不包含本机证书私钥，也不是 Apple 开发者 ID 签名或公证的正式发行包。
首次启动可能被 Gatekeeper 拦截，升级后可能需要重新授权录屏。日常本机使用仍建议复用现有本机自签证书。
详细说明见 [截图、贴图与标注开发文档](SCREENSHOT-DEVELOPMENT.zh-CN.md)。

分支推送和 Pull Request 仅修改文档时不触发自动构建或发布；代码、构建配置和应用资源改动仍会构建。
版本标签和手动构建不受文档过滤影响。

## 上游来源与许可

- 原项目与源码：**[p0deje/Maccy](https://github.com/p0deje/Maccy)**；感谢原作者及贡献者。
- 原项目采用 **MIT License**，原始版权声明和完整许可原样保留于 [LICENSE](LICENSE)，
  并随本修改版的应用及下载包一同分发。修改版新增代码亦按 MIT License 提供。
- 本仓库不是原项目的官方版本，与原作者不存在隶属、赞助、认可或背书关系；
  本修改版的问题请提交到本仓库，不要要求上游为新增功能提供支持。
- Maccy 名称仅用于说明上游来源；本项目不主张取得原项目名称、商标或图标的专有权，
  也不将开源代码许可解释为对所有品牌、图标或其他素材的授权。公开推广前应另行核查这些权利，
  并优先采用独立名称与自行制作的图标。
- 所用第三方组件仍适用各自许可证，不能仅凭本仓库的 MIT 标识忽略其要求。
  自动打包会收集锁定依赖的许可和通知文件，并放入应用的 `Contents/Resources/ThirdPartyLicenses/`。
  分发说明见 [分发说明](DISTRIBUTION-NOTICE.zh-CN.md)。

署名和免责声明不能保证不存在其他权利争议；本说明不是法律意见。

## 上游原版说明

原项目的剪贴板使用方法、进阶设置和常见问题保留在
[英文文档的上游说明部分](README.md#upstream-documentation)。
其中的官网、下载、徽章及支持链接均属于**原版项目**，
不表示本修改版获得官方认可，也不包含本修改版功能。
