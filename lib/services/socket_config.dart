/// RootID 1.0 WebSocket 环境入口：**发布 / 真机联调只改这一处即可**。
///
/// - **本机 + iOS 模拟器**：`ws://100.74.60.98:8080`（需先在本机启动 `rootid-server`：`npm start`）
/// - **Android 模拟器**访问宿主机：常用 `ws://10.0.2.2:8080`
/// - **真机（手机）访问局域网内的 Mac**：把主机改为 **Mac 的局域网 IP**
///   （系统设置 → 网络，如 `192.168.1.10`），即 `ws://192.168.1.10:8080`，
///   并确保 Mac 防火墙放行 **8080**，且手机与 Mac 同一 Wi‑Fi。
const String kDefaultSocketUrl = 'ws://100.74.60.98:8080';

/// 连接失败时由 [SocketService] 推给 UI（SnackBar），文案保持直白可行动。
const String kSocketConnectionFailureHint =
    '无法连接消息服务器。请确认电脑已运行 rootid-server（在 rootid-server 目录执行 npm start，默认端口 8080）。'
    '若用手机调试，请把 lib/services/socket_config.dart 里的 kDefaultSocketUrl 改成 Mac 的局域网 IP。';
