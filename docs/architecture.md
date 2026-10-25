# 架构说明

## 进程

| 进程 | 位置 | 说明 |
|---|---|---|
| `ipsentinel-panel` | 主控 `127.0.0.1:8080` | 面板 UI + API + 任务队列 + 存活探测 |
| `caddy` / `nginx` | 主控 `:443` | TLS 终止与反代 |
| `ip-sentinel-agent-daemon` | 每台节点 `:9527` | 上游 Agent，TLS + HMAC 鉴权 |
| `ip-sentinel-runner.timer` | 每台节点 | 每 20 分钟触发一次养护 |

## 数据流

```
面板按钮
  → POST /api/nodes/<id>/action
  → 写 commands 表（queued）
  → worker（并发上限 8）
  → 签名 URL 请求节点 https://<ip>:9527/trigger_*
  → 更新 commands（done/failed）与 nodes.last_seen
```

Agent 主动上报时走另一条：

```
Agent → https://<面板>/api/agent/tgshim/botPANEL/sendMessage
      → 面板按 chat_id（即 PSK）匹配节点
      → 存 reports，解析分数写入 trend
```

## 鉴权

- **人 → 面板**：口令（PBKDF2-SHA256）+ HttpOnly/SameSite=Strict 会话 + 登录限速
- **面板 → 节点**：`HMAC-SHA256(PSK, "path?query:timestamp")`，±60 秒有效，Agent 侧另做 nonce 防重放
- **节点 → 面板**：注册接口按来源 IP 限速；上报接口用 PSK 识别节点

## 数据表

- `nodes`：节点清单（含 `status`、`reachable`、`agent_version`）
- `commands`：指令流水（含 `batch_id`，用于批量进度）
- `reports`：Agent 上报原文
- `trend`：解析后的信用分与三态

## 设计取舍

- **不用前端框架**：1 核 1G 也能跑，升级只换文件
- **不做静默 OTA**：升级必须人工触发，避免重蹈上游的供应链风险
- **批量并发限 8**：500 台裸并发会瞬间吃掉数 GB 内存
- **PSK 每节点独立**：上游用 chat_id 当密钥，面板模式下必须换成随机串
