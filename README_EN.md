# Net LFS

**English** | [中文](README.md)

> A **lightweight, highly reliable** large file transfer library designed for Garry's Mod, compatible with [gm_express](https://github.com/CFC-Servers/gm_express) **v1** services.

Like gm_express, Net LFS uploads data via HTTP to a gm_express-compatible service and notifies the receiver to download it using a single, tiny Protobuf message.

It shares the same concept as gm_express, but is more streamlined and reliable.

```lua
-- Broadcast a large file
NetLFS.SendRaw("stored_data", file.Read("huge_data_file.json", "DATA"))

-- Receive and save
NetLFS.RegisterReceiver("stored_data", function(data)
    file.Write("stored_data.json", data)
end)
```

## Features

### Compatible with gm_express v1 Services

Uses the four endpoints of the v1 service. Any service implementing them (the official `gmod.express` or a self-hosted instance) can be used directly:

| Endpoint | Purpose |
| --- | --- |
| `GET  /v1/register` | Get server / client tokens and expiration time |
| `POST /v1/write/{token}` | Upload |
| `GET  /v1/read/{token}/{id}` | Download |
| `GET  /v1/size/{token}/{id}` | Query data size |

The service URL and API revision can be configured in-game (`net_lfs_baseurl`, `net_lfs_revision`, shared between server and client).

### High Reliability

- **Fully Automated Token Management**: Automatically refreshes tokens upon expiration.
- **Automatic Recovery from Token Expiration**:
    - Upon receiving a 401 (token invalid / expired), the server marks the token as invalid and hands it over to the existing refresh loop to re-acquire it. Requests are queued and automatically retried after the refresh.
    - When the client has no token yet or receives a 401, requests are queued and automatically retried once a new token is received.
- **Network Failure Retry**: Automatically retries with a delay if `http.Fetch` fails (e.g., connection errors).
- **Integrity Verification**: Downloaded content must match the SHA256 hash provided by the sender before it is passed to the receiver callback and written to the cache; cached reads are also verified. Hashes are strictly validated as pure hexadecimal before being concatenated into cache paths to prevent path injection.
- **Optional Pre-download Check**: Allows rejecting overly large files before downloading, and detects if a file has already expired.
- **Send Success Callback**: The sender can receive a callback when "the target has received and processed the data"; the server independently tracks acknowledgments for each target player and prevents replay attacks.
- **Reload-Safe**: All states are stored in `NetLFS.Cache`, ensuring tokens, queues, and cache records are not lost during Lua refreshes (hot-reloads).
- **Caching Mechanism**:
  - Download Cache: Received files are saved named after their hash; subsequent messages with the same hash use the cache directly.
  - Upload Cache: Sending the exact same data again within 12 hours directly reuses the previous upload result.

### Lightweight

- **Small Codebase**: The entire implementation is around 500 lines of code (compared to 1,485 lines in gm_express).
- **Protobuf for Control Messages**: Uses RiceLib's Protobuf module; all control messages are transmitted via Protobuf.

## Feature Comparison

| | net | NetStream | gm_express | **Net LFS** |
| --- | --- | --- | --- | --- |
| Transport Channel | net channel | net channel | HTTP, net notification | **HTTP, Protobuf notification** |
| Requires External Service | No | No | Yes | Yes (**compatible with gm_express v1**) |
| Data Model | Type-by-type read/write | Table | Table | **Raw Binary only (encode structured data yourself)** |
| Theoretical Single Limit | < 64 KB | < 64 KB (chunked) | None | None |
| Large Data Speed | Slow (manual chunking) | Very Slow | Fast | Fast |
| Small Data Speed | Fast | Slower than net | Slower than net (always uses HTTP) | **Fast, uses net channel for data < 64 KB** |
| Blocks Main Thread / Game Net | Yes | Yes | No | No |
| Concurrency | Handled manually | 1 request at a time, blocks all other transfers | Supported | Supported |
| Number of net Messages | 1 per 64 KB | Extremely high (1,485 msgs for 11 MB in Express tests) | 2 | **1** (without file size check) |
| Duplicate Data Caching | - | - | Upload cache | **Upload cache, Download cache** |
| Integrity Verification | - | - | Unspecified | **SHA256** |
| Failure Recovery | - | - | Unspecified | **Auto token refresh, 401 queue & retry, network failure retry** |
| Delivery Acknowledgment | - | - | Yes | Yes |
| Pre-download Interception | - | - | Yes | Yes |
| Dependencies | None | NetStream library | Built-in serializer | RiceLib |

> **Note on Performance**: The official Express README provides benchmarks comparing it against manual chunking and NetStream (when data exceeds ~3 net messages, the HTTP approach is several times or even an order of magnitude faster without blocking other messages; however, for small data around 12 KB, it is slower than manual chunking). Net LFS uses the same concept, thus sharing the same structural advantages for large data while using the standard `net` channel directly for small data. This project does not publish separate benchmarks; actual speeds depend on your service host and network conditions.

## Installation

1. Install the dependency library [lib-rice](https://gitea.sv.wolf109909.top:4443/RiceMCUT/Lib-Rice).
2. Clone this repository into `garrysmod/addons/`.
3. (Optional) Set `net_lfs_baseurl` on the server to your self-hosted gm_express-compatible service URL. Defaults to https://gm-express.anon-nanning.party (an express-compatible service).

## API

### `NetLFS.RegisterReceiver(id, callback, shouldReceiveFile)`

Registers a receiver.

- `callback(data, player)`: Called when data is received and passes verification. `data` is a raw string; `player` is the sending player on the server, and `nil` on the client.
- `shouldReceiveFile(file_id, file_hash, player, size)` (optional): Called before downloading. Return `false` to reject the download. `size` is the byte count reported by the service. **Only takes effect for large files using HTTP; not called for small data or local cache hits.**

```lua
NetLFS.RegisterReceiver("preferences", function(data, ply)
    ply.preferences = util.JSONToTable(data)
end, function(file_id, file_hash, ply, size)
    if size <= 1024 * 1024 then return true end

    print(ply, "attempted to send", size, "bytes of data, rejected")

    return false
end)
```

### `NetLFS.SendRaw(target_receiver, data, target, onTargetReceived)`

Sends raw data.

- `onTargetReceived(player)` (optional): Called after the target receives and processes the data. Acknowledgment records expire after 5 minutes.

```lua
-- Server -> Multiple players, with acknowledgment
NetLFS.SendRaw("prop_mesh", util.TableToJSON(meshData), {ply1, ply2}, function(ply)
    receivedMesh[ply] = true
end)

-- Client -> Server
NetLFS.SendRaw("bulk_admin_actions", util.TableToJSON(actions), nil, function()
    myPanel:StopSpinner()
end)
```

### Hooks

| Name | Description |
| --- | --- |
| `NetLFS_RefreshToken(token_server, token_client)` | Triggered after the server successfully refreshes tokens |
| `NetLFS_RefreshEndPoint(endpoint)` | Triggered after the service URL / API revision is modified |

### Console Commands

| Name | Description |
| --- | --- |
| `net_lfs_refresh_token` | Force refresh tokens (Console or Superadmin only) |

## Workflow

```text
Sender                      gm_express Service                    Receiver
  │  Data < 64000 B ──────────── net: NetPayload ───────────────────▶│
  │                                                                  │
  │  Data ≥ 64000 B                                                  │
  │── POST /write/{token} ────────▶│                                 │
  │◀── {"id": ...} ───────────────│                                 │
  │──────── net: Receive(id, sha256) ───────────────────────────────▶│
  │                                │◀── GET /size/{token}/{id} ──────│ (if shouldReceiveFile is registered)
  │                                │◀── GET /read/{token}/{id} ──────│ (writes to cache after SHA256 check)
  │◀─────────────────────── net: Ack ───────────────────────────────│
```

## Notes

- The upload cache is only recorded locally; if the remote service deletes the file prematurely, the receiver's download will fail.
- Modifying the BaseURL or Revision will trigger the `NetLFS_RefreshEndPoint` hook and clear both upload and download cache records.
## License

This project is licensed under the [GNU GPLv3](LICENSE).
