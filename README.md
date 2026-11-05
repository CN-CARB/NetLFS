# Net LFS

[English](README_EN.md) | **中文**

> 为 Garry's Mod 设计的**轻量、高可靠**大文件传输库，兼容 [gm_express](https://github.com/CFC-Servers/gm_express) **v1** 服务

Net LFS 与 gm_express 一样，把数据通过 HTTP 上传到 gm_express 兼容服务，只用一条极小的 Protobuf 消息通知接收端下载

思路与 gm_express 一致，但更精简可靠

```lua
-- 广播一个大文件
NetLFS.SendRaw("stored_data", file.Read("huge_data_file.json", "DATA"))

-- 接收并保存
NetLFS.RegisterReceiver("stored_data", function(data)
    file.Write("stored_data.json", data)
end)
```

## 特性

### 兼容 gm_express 服务 v1

使用 v1 服务的四个接口，任何实现了它们的服务（官方 `gmod.express` 或自建实例）都可以直接使用：

| 接口 | 用途 |
| --- | --- |
| `GET  /v1/register` | 获取服务端 / 客户端 token 及过期时间 |
| `POST /v1/write/{token}` | 上传 |
| `GET  /v1/read/{token}/{id}` | 下载 |
| `GET  /v1/size/{token}/{id}` | 查询数据大小 |

服务地址和 API 版本可在游戏内配置（`net_lfs_baseurl`、`net_lfs_revision`，两端共享）

### 高可靠

- **Token 全自动管理**：token过期自动刷新
- **Token 过期自动恢复**：
    - 请求收到 401（token 失效 / 过期）后，服务端把 token 标记失效并交给现有的刷新循环重新获取，请求排队等待，刷新后自动重试
    - 客户端尚无 token、或收到 401 时，请求进入队列，收到新 token 后自动重试
- **网络失败重试**：`http.Fetch` 失败（连接错误等）自动延时重试
- **完整性校验**：下载内容必须与发送方给出的 SHA256 一致才会交给接收回调、写入缓存；缓存读出后同样校验。哈希限定为纯十六进制后再拼进缓存路径，防止路径注入
- **可选预下载检查**：可在下载前拒绝过大的文件，也能发现文件已过期
- **发送成功回调**：发送方可以拿到「目标已收到并处理完毕」回调；服务端对每个目标玩家独立确认且防止重放
- **重载安全**：所有状态都放在 `NetLFS.Cache`，Lua 刷新不会丢失 token、队列和缓存记录
- **缓存机制**：
  - 下载缓存：接收的文件以哈希命名保存，下次收到相同哈希的消息直接使用缓存
  - 上传缓存：同一份数据 12 小时内再次发送，直接复用上次的上传结果

### 轻量

- **代码量小**：整个实现约500行代码 (gm_express为1485行)
- **控制消息用 protobuf**：使用RiceLib的Protobuf模块，所有控制消息均使用Protobuf

## 功能对比

| | net | NetStream | gm_express | **Net LFS** |
| --- | --- | --- | --- | --- |
| 传输通道 | net 通道 | net 通道 | HTTP，net 通知 | **HTTP，Protobuf 通知** |
| 需要外部服务 | 否 | 否 | 是 | 是（**可兼容 gm_express v1 服务**） |
| 数据模型 | 逐类型读写 | 表 | 表 | **当前仅原始字符串（结构化数据自行编码）** |
| 单条理论上限 | < 64 KB | < 64 KB (分块发送) | 无 | 无 |
| 大数据速度 | 慢(手动分块) | 非常慢 | 快 | 快 |
| 小数据速度 | 快 | 比 net 慢 | 比 net 慢（一律使用 HTTP） | **快，小于64KB使用net通道** |
| 占用主线程 / 游戏网络 | 是 | 是 | 否 | 否 |
| 并发 | 自行处理 | 一次只处理一个请求，期间无法传输任何其他数据 | 支持 | 支持 |
| net 消息数 | 每 64 KB 一条 | 极多（Express 测试中 11 MB 数据需 1,485 条） | 2 条 | **1 条**（无文件尺寸确认时） |
| 重复数据缓存 | - | - | 发送缓存 | **发送缓存，下载缓存** |
| 完整性校验 | - | - | 未说明 | **SHA256** |
| 失败恢复 | - | - | 未说明 | **token 自动刷新、401 排队重试、网络失败重试** |
| 到达确认 | - | - | 有 | 有 |
| 下载前拦截 | - | - | 有 | 有 |
| 依赖 | 无 | NetStream 库 | 自带序列化器 | RiceLib |

> 关于性能：Express 官方 README 中给出了它与手动分块、NetStream 的实测对比（数据超过约 3 条 net 消息时，HTTP 方案快数倍乃至一个数量级，并且不阻塞其他消息；约 12 KB 的小数据则比手动分块慢）。Net LFS 使用同样的思路，因此在大数据场景有同样的结构性优势，小数据则直接使用 net；本项目没有单独发布基准数据，实际速度取决于你的服务和网络条件。

## 安装

1. 安装依赖库 [lib-rice](https://gitea.sv.wolf109909.top:4443/RiceMCUT/Lib-Rice)
2. 将本项目克隆至 `garrysmod/addons/`。
3. （可选）在服务端设置 `net_lfs_baseurl` 为自建的 gm_express 兼容服务地址，默认 https://gm-express.anon-nanning.party (express兼容服务)

## API

### `NetLFS.RegisterReceiver(id, callback, shouldReceiveFile)`

注册接收端

- `callback(data, player)`：收到并校验通过的数据。`data` 为原始字符串；服务端的 `player` 是发送玩家，客户端为空。
- `shouldReceiveFile(file_id, file_hash, player, size)`（可选）：下载前调用，返回 `false` 拒绝下载。`size` 为服务端报告的字节数。**仅使用 HTTP 的大文件生效，小数据和本地缓存命中不会调用**

```lua
NetLFS.RegisterReceiver("preferences", function(data, ply)
    ply.preferences = util.JSONToTable(data)
end, function(file_id, file_hash, ply, size)
    if size <= 1024 * 1024 then return true end

    print(ply, "试图发送", size, "字节的数据，已拒绝")

    return false
end)
```

### `NetLFS.SendRaw(target_receiver, data, target, onTargetReceived)`

发送原始数据

- `onTargetReceived(player)`（可选）：目标收到并处理完毕后调用，确认记录 5 分钟后过期

```lua
-- 服务端 -> 多个玩家，并确认
NetLFS.SendRaw("prop_mesh", util.TableToJSON(meshData), {ply1, ply2}, function(ply)
    receivedMesh[ply] = true
end)

-- 客户端 -> 服务端
NetLFS.SendRaw("bulk_admin_actions", util.TableToJSON(actions), nil, function()
    myPanel:StopSpinner()
end)
```

### 钩子

| 名称 | 说明 |
| --- | --- |
| `NetLFS_RefreshToken(token_server, token_client)` | 服务端刷新 token 成功后触发 |
| `NetLFS_RefreshEndPoint(endpoint)` | 服务地址 / API 版本被修改后触发 |

### 控制台命令

| 名称 | 说明 |
| --- | --- |
| `net_lfs_refresh_token` | 强制刷新 token（仅控制台或超级管理员） |

## 工作流程

```text
发送方                       gm_express 服务                      接收方
  │  数据 < 64000 B ──────────── net: NetPayload ───────────────────▶│
  │                                                                  │
  │  数据 ≥ 64000 B                                                  │
  │── POST /write/{token} ────────▶│                                 │
  │◀── {"id": ...} ───────────────│                                 │
  │──────── net: Receive(id, sha256) ───────────────────────────────▶│
  │                                │◀── GET /size/{token}/{id} ──────│ (注册了 shouldReceiveFile)
  │                                │◀── GET /read/{token}/{id} ──────│ (校验 SHA256 后写入缓存)
  │◀─────────────────────── net: Ack ───────────────────────────────│
```

## 注意

- 上传缓存只记录在本机；若服务提前删除了文件，接收方下载会失败。
- 修改BaseURL、Revision会触发 `NetLFS_RefreshEndPoint` 钩子并清空上传 / 下载记录

## 许可证

本项目以 [GNU GPLv3](LICENSE) 授权。
