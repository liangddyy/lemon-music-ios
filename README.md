# Lemon Music iOS

柠檬音乐的原生 iPhone 客户端，直接连接 [Lemon Music](https://github.com/jia070310/lemon-muisc) 提供的 `/api/v1`。

[TestFlight 测试](https://testflight.apple.com/join/gHGkBvKr)

## 功能

- 音乐库、在线搜索与发现、收藏和歌单
- 后台播放、锁屏控制、AirPlay、播放队列和歌词
- CarPlay：最近播放、收藏、歌单和音乐库，使用系统播放页
- 下载到 NAS、手动缓存到手机、可关闭的边播边缓存
- 跟随服务器转码设置，原文件与 AAC 缓存分开保存
- 默认紧凑显示，支持系统动态字体

音频缓存默认上限 2 GB，可在设置中调整。关闭自动缓存不影响已有缓存或手动缓存。
手动缓存默认使用 Wi-Fi，蜂窝网络需单独确认。连接服务端需要先配置音乐库和可用音源。

## 要求

- iOS 18+
- Xcode 26+

## 构建

1. 打开 `LemonMusic.xcodeproj`。
2. 在 `LemonMusic` Target 中选择自己的开发团队。
3. 选择 iPhone 或 iOS Simulator，运行 Scheme `LemonMusic`。
4. 首次启动输入服务器地址、用户名和密码。

## CarPlay

手机和车机共用账号、播放器及缓存。先在 iPhone 上登录，再从 CarPlay 打开柠檬音乐。
支持歌单播放、播放队列、播放/暂停、上下曲、随机播放和循环模式，不提供车机搜索、
歌词、下载或歌单编辑。

真机使用前，开发团队需取得 Apple 的 CarPlay Audio 权限，并为 `top.btop.music`
启用对应能力、更新签名描述文件。工程中的 entitlement 声明不代表审批或签名配置已完成。
模拟器可通过 Simulator 的 `I/O > External Displays > CarPlay` 验证车机界面。

## 测试

按需运行 `LemonMusicTests` 或 `LemonMusicUITests` Scheme。

## 许可证

本项目基于 Cassette 二次开发，派生文件继续遵循 MPL-2.0。播放器使用本地固定并扩展的 AudioStreaming 1.4.4，其 MIT 许可保留在 `Vendor/AudioStreaming/LICENSE`。其他原始版权及许可信息见 `LICENSE`、`NOTICE` 和 `COPYRIGHT`。
