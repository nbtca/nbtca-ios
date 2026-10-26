# NBTCA iOS App（拔电关机）

NBTCA 拔电关机 iOS 客户端，采用 **Swift + SwiftUI** 原生架构开发，支持 **iPhone 与 iPad**。

本仓库专用于 **iOS / iPadOS 端**客户端的开发与维护，与 [Android 客户端](https://github.com/nbtca/nbtca-app)共用协会资讯、维修和基础设施服务。学校查询对接浙大宁波理工学院教务与学工系统。

---

## 📱 核心功能特性

1. **资讯广场（Newsroom）**
   - 协会资讯、分类切换、搜索与系统分享
   - 原文及 Markdown 阅读，支持图片、表格、代码与深浅色主题
   - 优先展示本地资讯缓存，已保存的文章正文可离线阅读

2. **电脑报修（Repair）**
   - 维修预约、AI 故障预检、维修日安排与工单进度追踪
   - 支持报修用户、技术员及管理员角色：编辑与取消、接单、报告提交及审核结单
   - 状态筛选与分页，刷新失败保留已有记录
   - 现场照片压缩、上传进度与失败重试，报修及报告文字草稿自动恢复

3. **教务查询（Academic）**
   - 学校统一身份认证，校园网直连与 WebVPN 自动切换
   - 课表、考试、成绩独立入口，支持学年学期选择
   - 周课表默认定位本周，展示单双周、跨节及重叠课程；本地课表可离线查看
   - 课表导出到苹果日历，预览新增、更新与失效日程后确认同步
   - 首页显示下一节课提醒；学校密码不由 App 读取或保存

4. **寝室文明查询（Dormitory）**
   - 对接学校学工系统，与教务共用学校登录会话
   - 按学年学期筛选，搜索检查日期、寝室、分数及扣分说明
   - 并列展示宿舍分数、个人分数与总分，详情保留各自备注

5. **社团工具（Tools）**
   - 协会活动日历与日历订阅入口
   - 基础设施状态、异常组件和服务事件
   - 协会文档与官方网站入口

6. **个人中心（Profile）**
   - 基于 **Logto OAuth2 + PKCE** 登录，使用钥匙串保存凭证并自动续期
   - 按账号实际权限切换报修用户、技术员与管理员视角
   - 跟随系统、浅色与深色外观，以及自定义 BFF 地址
   - iPad 自适应布局与多窗口查询，各页面独立保存查询状态

---

## 🛠️ 技术架构

| 项目 | 实现 |
| --- | --- |
| 语言与界面 | Swift、SwiftUI、Observation |
| 最低系统 | iOS / iPadOS 18.0 |
| 网络与异步 | URLSession、Swift Concurrency |
| 登录与安全存储 | WebKit、CryptoKit、Keychain |
| 文章阅读 | 隔离的 WKWebView，随 App 打包 markdown-it 与 DOMPurify |
| 图片处理 | ImageIO 后台缩放与缩略图生成 |
| 日历同步 | EventKit |
| 构建工具 | Xcode，无第三方 Swift 包依赖 |

资讯、活动日历、服务状态和 AI 预检通过 BFF 请求；维修业务直连 Saturday。学校查询由设备直接访问学校系统，两套登录相互独立。

---

## 🚀 编译与调试

### 1. 环境准备

- **macOS + Xcode**：当前工程已在 Xcode 27.1 下验证
- **运行设备**：iOS / iPadOS 18.0 及以上
- **真机签名**：在 Xcode 的 Signing & Capabilities 中选择自己的开发团队，按需修改 Bundle Identifier

### 2. 获取代码并运行

```bash
git clone https://github.com/nbtca/nbtca-ios.git
cd nbtca-ios
open nbtca.xcodeproj
```

选择 `nbtca` scheme 和目标设备，点击 **Run**。

默认连接 `https://bff.nbtca.space/api/v1`，无需在本机启动后端。需要调试其他 BFF 时，可在 **个人中心 → 后端服务器** 修改地址。真机连接本机服务时请使用电脑的局域网地址。

Debug 支持 HTTP 调试，Release 自定义地址需使用 HTTPS。后端服务源码与部署说明见 [nbtca/nbtca-app](https://github.com/nbtca/nbtca-app)。

### 3. 编译检查

```bash
xcodebuild -jobs 2 -project nbtca.xcodeproj -scheme nbtca \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

该命令用于无签名编译验证，不会启动模拟器，产物不能直接安装到真机。

### 4. 运行测试

```bash
python3 Scripts/test-academic.py
```

脚本在临时目录运行协议与回归测试，覆盖教务与寝室解析、登录导航、课表周次与缓存、日历差异、维修接口、资讯缓存、草稿和图片处理。测试使用虚构数据与模拟响应，无需学校账号或模拟器。

文章渲染测试另见 [开发说明](docs/DEVELOPMENT.md#文章阅读)。真实学校登录、网络切换、维修业务及系统日历写入仍需在设备上联调。

---

## 📂 项目结构

```text
nbtca/
├── Core/                 # 网络、认证、模型、草稿与通用组件
├── Features/             # 资讯、维修、工具与个人中心
│   └── Academic/         # 学校登录、课表、考试、成绩与寝室查询
├── Resources/            # 文章阅读资源、已核对校历与第三方声明
└── Assets.xcassets/      # 图标与颜色资源
nbtcaTests/               # 协议与回归测试
Scripts/                  # 测试与图标生成脚本
Config/                   # Debug 网络配置
docs/DEVELOPMENT.md        # 接口、缓存、认证与验证细节
```

## 🔗 相关项目

- [nbtca/nbtca-app](https://github.com/nbtca/nbtca-app)：Android 客户端与 Go BFF
- [nbtca/Prompt](https://github.com/nbtca/Prompt)：学校查询实现参考
- [nbtca/nbtcal](https://github.com/nbtca/nbtcal)：校历与课表协议参考
- [NBTCA 官方网站](https://nbtca.space)

第三方组件与参考实现的许可声明随项目保留，详见 [学校查询声明](nbtca/Resources/AcademicNotices.txt) 和 [文章阅读组件声明](nbtca/Resources/ArticleReader/ThirdPartyNotices.txt)。
