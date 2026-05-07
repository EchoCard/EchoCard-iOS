# App Store 审核回信 — Guideline 2.1(b) 商业模式说明

本文档供在 **App Store Connect** 回复审核团队时使用。请根据实际上架构建与商务安排核对后再发送。

| 项目 | 内容 |
|------|------|
| 审核条目 | Guideline 2.1(b) – Information Needed |
| Submission ID（示例） | `83649e9b-0732-4027-8abc-26977253c0e1` |
| 审核日期（示例） | 2026-05-06 |
| 产品 / 品牌 | **EchoCard**（商店展示名可参考：**EchoCard AI代接卡**） |
| 应用名称（工程内） | CallMate（与 EchoCard 硬件配套） |

## 开发主体 / 注册信息（法定）

以下信息与工商及 App Store Connect 开发者账号应保持一致（若 Connect 显示略有差异，以 **Connect 为准**）。

| | |
|--|--|
| 英文法定名称 | Longshu (Shenzhen) Artificial Intelligence Co., Ltd |
| 中文法定名称 | 龙树（深圳）人工智能有限公司 |
| 地址（英文） | B316, East, Lenovo Building, No. 016, Gaoxin South First Road, Gaoxin District Community, Yuehai Street, Nanshan District, Shenzhen, Guangdong 518000, China |

**中文地址：** 广东省深圳市南山区粤海街道高新区社区高新南一道016号联想大厦东楼B316（邮编 518000）

工程内 Bundle ID 前缀为 `greater.longshu`，与英文商号 **Longshu** 对应。

---

## 英文回信正文（建议直接粘贴到 App Store Connect）

**为什么会出现中文夹杂：** 早期草稿里用中文写的是「内部占位提示」（提醒自己填渠道、是否保留 IAP 说明），**不应**出现在发给审核团队的英文信中。下面 **「可复制英文正文」** 区块内仅为英文；填写说明放在其后 **「勿粘贴进 Connect」** 小节。

---

### 可复制英文正文（纯文本，无 Markdown）

可选标题行（如需）：
Re: Guideline 2.1(b) – Business model clarification (Submission ID: 83649e9b-0732-4027-8abc-26977253c0e1)

——— 以下为粘贴到 App Store Connect 的正文（从这里复制）———

Hello App Review Team,

Thank you for your message. Below are detailed answers about our business model.

1) Who are the users that will use the paid content, subscriptions, features, and services in the app?

Our users are people who are frequently disturbed by unknown numbers or marketing/spam calls and want an AI-assisted phone experience when using our app together with the EchoCard hardware.

2) Where can users purchase the content, subscriptions, features, and services that can be accessed in the app?

Hardware (EchoCard device): Users purchase the physical EchoCard device through various e-commerce channels (authorized online retailers and marketplace storefronts). Pairing the purchased hardware with the app is required to use the core AI call-assistant features.

Digital subscriptions and In-App Purchase: The submitted build under review does not include any subscription or In-App Purchase products. The app’s functionality is tied to pairing with the purchased EchoCard hardware. If we offer subscription or other digital entitlements inside the iOS app in the future, they will be available only through Apple In-App Purchase, in compliance with the App Store Review Guidelines.

3) What specific types of previously purchased content, subscriptions, features, and services can a user access in the app?

After purchasing an EchoCard device and binding/pairing it in the app, users can use the AI call-assistant capabilities associated with that hardware. Users may view history and analysis of AI-handled calls. This information is stored locally on the user’s device and is not stored on our servers as part of this product design.

4) What paid content, subscriptions, or features are unlocked within the app that do not use In-App Purchase?

We do not sell separate digital unlock codes or paid digital features through external channels that unlock iOS app functionality. Core functionality is tied to ownership and pairing of the physical EchoCard device, which is a physical product purchased outside the app. When we introduce subscription-based digital features in the app, those will use In-App Purchase.

Please let us know if you need demo steps for hardware pairing or any additional information.

Best regards,
Guanghao Li
Client Development Engineer
Longshu (Shenzhen) Artificial Intelligence Co., Ltd.
B316, East, Lenovo Building, No. 016, Gaoxin South First Road, Gaoxin District Community, Yuehai Street, Nanshan District
Shenzhen, Guangdong 518000
China

——— 正文结束 ———

---

### 英文正文填写说明（勿粘贴进 App Store Connect）

- Hardware 一句：当前正文已写为「各类电商渠道」。若审核追问具体平台名称，再在英文信中补充列举（仍保持纯文本，勿用 Markdown）。
- 当前文档按「提交版本无 IAP / 无订阅」定稿。若日后某次提交已上线 IAP，须同步改写问题 2 英文段：删除「does not include any subscription or In-App Purchase」等句，改为如实列出 IAP / 订阅产品（纯英文）。
- 粘贴前全文检查：发给 Apple 的正文不应出现任何中文字符；也不要把本节说明复制进去。

---

## 中文对照（便于内部审核；若用中文回复 Apple 请用下列纯文本，勿带 Markdown）

——— 中文回信正文（纯文本）———

您好，

感谢来信。以下为我们商业模式的补充说明：

1. 用户群体：频繁遭受陌生来电、营销骚扰电话困扰，希望通过 EchoCard 硬件与 App 获得 AI 代接或来电辅助能力的用户。

2. 购买渠道：EchoCard 实体硬件通过各种电商渠道购买；用户在 App 内完成绑定后使用核心能力。当前提交版本不包含任何订阅或 App 内购买（IAP）。未来若在应用内提供订阅或其他数字权益，将仅通过苹果 App 内购买提供。

3. 已购权益在 App 内的体现：绑定已购硬件后可使用与硬件配套的 AI 代接相关能力；用户可查看 AI 代接的历史通话记录与分析；相关数据保存在用户本机，按当前产品设计不上传至我方云端存储。

4. 未使用 IAP 的付费解锁：不存在通过外部渠道购买数字解锁码等方式在 App 内解锁功能的做法；核心能力与已购实体硬件的绑定相关。未来若在 App 内提供订阅类数字权益，将使用 IAP。

此致
李光浩
客户端开发工程师
龙树（深圳）人工智能有限公司

——— 结束 ———

---

## 发送前自检清单

- [ ] 硬件销售渠道表述（电商渠道）与商务实际一致；若审核要求细化，已准备可补充的平台名单。  
- [ ] 已与二进制核对：当前提交版本确无订阅与 IAP；日后若上架 IAP，须更新本文档中英文问题 2 表述。  
- [ ] 隐私政策、App 隐私标签与「本地存储、不上云」等表述一致（若日后改为云端同步，需同步更新文案与审核说明）。  
- [ ] 落款公司名与 App Store Connect 法律实体一致（应为 Longshu (Shenzhen) Artificial Intelligence Co., Ltd / 龙树（深圳）人工智能有限公司）。

---

## 测试用例

- [ ] 打开 App Store Connect → 该 App → 版本 → 审核信息 → 回复审核 → 粘贴英文正文 → 核对 Submission ID 与版本号 → 发送。  
- [ ] 若审核追问 IAP：确认应用中无任何「外链购买数字会员再在 App 内解锁」的流程；若有，须改为 IAP 或移除。
