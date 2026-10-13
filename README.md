# Lemon Music iOS

柠檬音乐的原生 iPhone 客户端，直接连接 [Lemon Music](https://github.com/jia070310/lemon-muisc) 提供的 `/api/v1`。

[TestFlight 测试](https://testflight.apple.com/join/gHGkBvKr)

## 功能

- 音乐库、在线搜索与发现、收藏和歌单
- 后台播放、锁屏控制、AirPlay、播放队列和歌词
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

当前不包含 CarPlay。

## 测试

按需运行 `LemonMusicTests` 或 `LemonMusicUITests` Scheme。

## 许可证

本项目基于 Cassette 二次开发，派生文件继续遵循 MPL-2.0。播放器使用本地固定并扩展的 AudioStreaming 1.4.4，其 MIT 许可保留在 `Vendor/AudioStreaming/LICENSE`。其他原始版权及许可信息见 `LICENSE`、`NOTICE` 和 `COPYRIGHT`。
