# 个人页面素材与文案

## 项目卡片

**名称**：LoL Connect · LOL 连接诊断助手

**中文短描述**：面向国服 LOL 的 Windows 连接诊断工具。记录启动异常、测试服务接口，并通过图形界面配置自己的分流线路。

**English**: A Windows tool for diagnosing League of Legends connection failures and configuring service-specific routes with your own proxies.

**标签**：Windows 桌面工具 / 网络诊断 / PowerShell / Python / WinForms / AI 辅助开发

## 个人页面正文

在香港连接国服 LOL 时，我遇到过“延迟正常，但大厅或加载界面进不去”的问题。单次测速无法解释不同游戏服务的连接情况，手写分流规则也不适合普通用户。

我从自己的排查过程出发，使用 AI 辅助开发了 LoL Connect：让用户正常打开游戏，标记卡住的位置，再把日志和连接证据整理成可读的诊断结果。需要换线路时，可以批量测试已有节点，为不同服务分配路径，并在应用前预览、之后恢复。

设计中最重要的取舍，是把“接口有响应”和“游戏真的能玩”分开。工具不提供节点，不把一次测试通过当成修复成功，也不会为了给出结论而隐藏证据不足的情况。

## English case summary

While connecting to mainland China LoL servers from Hong Kong, I encountered sessions where reported latency looked normal but the client could not reach the lobby or finish loading. I developed LoL Connect with AI assistance to turn the troubleshooting process into a guided Windows workflow: observe a launch, mark the stalled stage, review connection evidence, and optionally test and assign user-owned routes. The design separates endpoint reachability from actual gameplay and makes routing changes reviewable and reversible.

## 可展示的个人贡献

- 从真实连接问题定义使用场景，逐步将排查步骤整理成产品流程。
- 为不熟悉 IP 和代理规则的用户设计诊断引导、阶段标记和解释性结果页。
- 确定三类服务与单接口路径的控制方式，以及应用预览和恢复机制。
- 使用 AI 辅助实现并结合本机试用反馈迭代，明确日志证据、主动探测和真实游戏体验的区别。

不要把该项目写成自研加速专线、商业加速器、覆盖全部区服或已验证规模化产品。当前没有用户规模、性能提升百分比或跨运营商成功率统计。

## 素材清单

| 文件 | 用途 | 来源与说明 |
|---|---|---|
| `assets/cover.svg` | 个人项目卡片、仓库头图，1280 × 640 | 原创矢量排版；可缩放，不是应用界面 |
| `assets/home.png` | 展示普通用户入口 | 从干净、隔离数据目录启动实际应用生成；无私人节点 |
| `assets/observe.png` | 展示用户如何标记卡住阶段 | 作者提供的实际使用截图，原样保留 |
| `assets/diagnosis.png` | 推荐主图，展示工具的核心价值 | 作者提供的实际诊断截图；有超时与进展，不代表最终根因或修复效果 |

建议个人页面采用「结果图 + 三步流程 + 一段设计取舍」，而不是把所有窗口拼在一起。图注可写：“把启动异常整理成证据、进展和未检查项，避免只用延迟判断连接状态。”

## Description 写法参考

参考 [Ping Tracer](https://github.com/bp2008/pingtracer) 和 [MTR](https://github.com/traviscross/mtr) 对工具类别和具体行为的直接介绍。这里借鉴的是表达结构，不是复制文案或代码。不使用“革命性”“强大的一站式”“智能赋能”等没有具体依据的词。
