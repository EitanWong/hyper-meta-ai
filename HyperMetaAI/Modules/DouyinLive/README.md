# DouyinLive 模块

`DouyinLive` 将抖音账号会话、房间生命周期、Meta Ray-Ban 视频帧、RTMP 发布和实时互动消息封装在独立模块中。首页只依赖 `DouyinLiveModule.makeView(streamViewModel:)`，不接触房间接口、推流地址或消息协议。

## 组成

| 文件 | 单一职责 |
|---|---|
| `DouyinLiveModels.swift` | 领域模型与小粒度协议 |
| `DouyinAuthorizationCoordinator.swift` | 新二维码、外部路由和一键授权状态机 |
| `DouyinWebRuntime.swift` | 官方网页登录、二维码提取和 WebKit 请求执行器 |
| `DouyinWebcastAPIClient.swift` | 预检、建房、心跳、停播和统计接口 |
| `DouyinMessageTransport.swift` | 1 秒 polling、protobuf 解码与消息去重 |
| `DouyinMediaAdapters.swift` | Meta Ray-Ban 原始帧和 HaishinKit RTMP 适配 |
| `DouyinLiveCoordinator.swift` | 跨组件状态机与清理顺序 |
| `DouyinLiveView.swift` | 登录、开播、数据和互动消息界面 |
| `DouyinLiveModule.swift` | 组合根和可注入请求执行器 |

## 直播顺序

```text
点击登录
  -> 强制无缓存加载官方登录页
  -> 解码本次新生成的二维码
  -> snssdk1128://webview?url=... 直接打开抖音
  -> 回到 APP 后自动轮询并恢复网页登录会话
  -> user/me
  -> check_exist
  -> pc_live 权限和实名检查
  -> latest_room + create_info
  -> 获取 Meta Ray-Ban 相机租约
  -> create_room
  -> 从响应选择 rtmp_push_url
  -> HaishinKit 发布
  -> 5 秒主播心跳
  -> 1 秒 protobuf 消息 polling
  -> 房间统计刷新
```

授权流程不保存账号密码，也不要求用户复制二维码、RTMP 地址或推流密钥。每次初始登录和失败重试都会重新请求二维码；旧二维码不会被下一次尝试复用。授权准备、Scheme 路由和外部打开分别依赖小接口，后续可以增加其他官方登录方式而不修改直播房间或推流实现。

停播固定为：`status=4` 远端结束信号、停止本地发布、释放相机、`anchor_finish_info`、确认房间回到 `30001/30003` 空闲状态。任一步骤失败都会执行剩余清理。

## 请求保护边界

已验证的桌面请求链包含：

```text
a_bogus + msToken
  -> X-Helios + X-Medusa
  -> bd-ticket-guard-* headers
  -> response feedback
```

这些值与设备注册、会话和最终 URL/body/header 绑定。`DouyinWebRuntime` 只接受平台页面实际追加了动态 query 的请求；缺失时在建房前返回 `requestProtectionUnavailable`，不会伪造已登录或已开播状态。

真机已观察到只有 `a_bogus + msToken` 时，预检通过但建房返回 `4003166`；该状态映射为 iOS 建房保护上下文未被接受，不再显示平台返回的误导性“更新直播软件”提示，且此时远端房间尚未创建。

默认配置始终使用网页登录会话标识，不会从环境变量、桌面客户端缓存或其他设备复制 DID/IID，也不会跨 `aid` 复用页面 `msToken`。这样可避免 iOS 客户端伪装成另一个直播客户端而让会话状态不可预测。

原生 iOS 的建房能力应通过 `DouyinLiveModule.makeView(streamViewModel:requestExecutorFactory:)` 注入，实现 `DouyinRequestExecuting` 即可。该执行器负责从抖音官方原生能力取得当前请求所需的会话与证明；账号、房间、消息、媒体和 UI 层不需要修改。

最近一次真机验证中，已登录会话、账号读取、房间空闲检查、直播权限检查和 `create_info` 均成功，`/webcast/room/create/` 返回 `4003166`，且远端房间保持空闲。因此模块会将该状态直接提示为缺少官方原生建房能力，并在没有合规原生执行器时不报告虚假的开播成功。

## 当前媒体范围

- 视频输入：Meta Ray-Ban DAT 原始 `CMSampleBuffer`。
- 输出：H.264 RTMP/RTMPS，默认 `504 x 504`、`2 Mbps`。
- 帧率：发布器以现有 HaishinKit 服务的 24 FPS 上限发送。
- 当前模块没有接入音频帧；后续音频发布应作为独立 adapter 加入，不改变房间和消息实现。

## 验证

```bash
xcodebuild \
  -project HyperMetaAI.xcodeproj \
  -scheme HyperMetaAI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:HyperMetaAITests
```

协议测试覆盖一键授权路由、二维码重试/并发/取消、动态 RTMP 地址优先级、弹幕/礼物/点赞/成员/房间统计解码；协调器测试覆盖开播、心跳和停播顺序。真机验收还需记录抖音授权落地页、会话回跳、请求保护、房间创建、RTMP publish start、互动消息和最终空闲房间七类结果。
