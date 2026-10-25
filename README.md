# IP-Sentinel Panel

> 给 [IP-Sentinel](https://github.com/hotyue/IP-Sentinel) 套一个 Web 控制台：一个主控、多台子机，浏览器里管理，不再依赖 Telegram。
>
> **非官方项目**，与上游作者无关。上游是 AGPL-3.0，本项目同样以 AGPL-3.0 发布。

## 它解决什么问题

上游的养护逻辑很好用，但控制面只有 Telegram：注册要转发暗号，操作要点 Inline Keyboard，趋势和日志基本没法看。
这个项目把控制面换成 Web：

- 主控 = 一台 VPS，跑面板 + 可选的本机 Agent
- 子节点 = 其它 VPS，装 Agent 后主动注册
- 浏览器登录主控，统一看状态、下指令、看趋势

**Agent 代码零改动**。面板复用上游的 HMAC 接口，只把上报地址指向自己。

## 特性

- **主动注册**：节点执行一条命令，自动识别区域并向主控报到，面板审批即接入
- **真假开关**：模块开关会真的下发到 Agent，不是只改数据库
- **批量下发**：舰队级触发，8 并发 + 进度条，不会把主控内存打爆
- **战区分组**：主控独占第一排，子节点按国家/州/城市分组
- **趋势与审计**：IP 信用分折线、每条指令的下发记录
- **响应式**：手机、平板、PC 自适应，手机上也能顺手操作
- **零前端依赖**：Python 标准库 + 原生 HTML/JS，1 核 1G 可跑

## 架构

```
        浏览器
          │ HTTPS
   ┌──────▼──────────┐
   │ 主控 VPS         │  Caddy / nginx（TLS 终止）
   │ ├ Panel :8080    │  SQLite + 任务队列 + 存活探测
   │ └ Agent :9527    │  本机自养护
   └──────┬───────────┘
          │ HMAC 签名请求（±60s，防重放）
   ┌──────▼───────┐   ┌──────────────┐
   │ 子节点 Agent  │   │ 子节点 Agent  │ ...
   └──────────────┘   └──────────────┘
          │ 上报（伪装成 Telegram sendMessage）
          └────────────► 面板 /api/agent/tgshim
```

## 快速开始

### 一、装主控

在一台公网 VPS 上（Ubuntu / Debian，1 核 1G 起），先确保域名已解析到这台机器：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<你的账号>/ip-sentinel-panel/main/install/master.sh) \
  --domain panel.example.com
```

脚本会：
1. 装依赖、部署面板、起 systemd
2. 按环境自动选 TLS：
   - 80/443 空闲 → 装 Caddy，自动签证书
   - 443 被 nginx 占用 → 只加一个 vhost，不动现有站点
   - 都没有 → 提示你手动配置
3. 可选在本机同时装 Agent（默认 y），并自动通过审批
4. 打印面板地址和初始口令

常用参数：

| 参数 | 说明 |
|---|---|
| `--domain` | 必填，面板域名 |
| `--tls` | `auto` / `caddy` / `nginx` / `none` |
| `--with-agent` | `y` / `n`，默认 `y` |
| `--port` | 面板本地端口，默认 `8080` |
| `--dry-run` | 只打印计划，不动系统 |

### 二、加子节点

在子节点上执行：

```bash
bash <(curl -fsSL https://panel.example.com/agent.sh) --master panel.example.com
```

脚本会自动：
1. 探测公网 IP → 查地理位置 → 匹配上游战区的国家/州/城市
2. 下载核心文件、UA 指纹池、词库、区域坐标
3. 写配置、生成 PSK、装 systemd 守护 + 20 分钟定时器
4. 发一次签名请求自测
5. 向主控注册

然后回面板 → 舰队 → **待审批** → 点「通过」。

可选参数：

```bash
--region US/VA/Ashburn   # 覆盖自动识别的区域
--node-id lax-02         # 自定义节点 ID
--port 9527              # Agent 端口
--enroll <注册码>         # 面板开启注册码模式时使用
--dry-run                # 只看识别结果
```

### 三、升级与卸载

```bash
# 升级主控（保留数据）
bash <(curl -fsSL https://panel.example.com/upgrade.sh)

# 卸载主控（保留数据库）
bash /opt/ip-sentinel-panel/src/install/uninstall.sh

# 卸载并删除数据
bash /opt/ip-sentinel-panel/src/install/uninstall.sh --purge
```

## 安全建议

- 面板只监听 `127.0.0.1`，公网只开 443
- 每个节点的 PSK 独立，不要复用
- 节点的 9527 只对主控出口 IP 放行：
  ```bash
  ufw allow from <主控IP> to any port 9527 proto tcp
  ```
- 首次登录后立刻到「设置」改口令
- 面板不做静默 OTA。升级永远是你手动执行，这是刻意设计

## 常见问题

**443 已经被别的服务占用怎么办？**
`--tls auto` 会检测到 nginx 并只加一个 vhost，不影响现有站点。如果占 443 的不是 nginx，用 `--tls none` 自己反代到 `127.0.0.1:8080`。

**节点在 NAT / 家宽后面能接入吗？**
能注册，但主控连不上它的 9527，因此无法下发指令。审批界面会显示「不可达」。这类节点需要反向拉取架构，目前未实现。

**重装节点后提示「节点已存在且已激活」？**
先在面板删除该节点再重跑，或者直接更新面板里的 PSK。

**为什么不用 Telegram 了？**
不是不能用，是不方便。面板保留了兼容垫片，Agent 以为自己在发 Telegram 消息。

## 目录结构

```
panel/            面板本体（Python 标准库）
install/master.sh 主控一键安装
install/agent.sh  节点一键安装 + 自动注册
install/upgrade.sh
install/uninstall.sh
docs/             架构与排障
```

## 许可与致谢

本项目以 **AGPL-3.0** 发布。

养护逻辑、指纹库、词库、区域数据均来自 [hotyue/IP-Sentinel](https://github.com/hotyue/IP-Sentinel)，版权归原作者。
本仓库只包含控制面代码，安装时按固定版本从上游拉取 Agent 文件。

如果你觉得上游项目有用，请给原仓库点个 Star。
