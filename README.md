# Lemon Music iOS

柠檬音乐的原生 iPhone 客户端，直接连接 Lemon Music 官方 FPK 提供的 `/api/v1`。

## 功能

- 本地音乐库：歌曲、专辑、歌手、流派和自定义歌单
- 在线音源：搜索、新歌、新碟和排行榜
- 后台播放、锁屏控制、AirPlay、播放队列和歌词
- SwiftData 元数据缓存与 stale-while-revalidate
- 边播放边写入的断点续传音频缓存，默认 2 GB 空间 LRU
- 单服务器、单账号，Token 仅存储在 Keychain

## 要求

- iOS 18+
- Xcode 26+
- 已部署并配置音乐库和音源的 Lemon Music 服务端

## 构建

1. 打开 `LemonMusic.xcodeproj`。
2. 在 `LemonMusic` Target 中选择自己的开发团队。
3. 选择 iPhone 或 iOS Simulator，运行 Scheme `LemonMusic`。
4. 首次启动输入服务器地址、用户名和密码。

CarPlay 尚未包含在一期版本中，也不声明 CarPlay entitlement。

## 许可证

本项目基于 Cassette 二次开发，派生文件继续遵循 MPL-2.0。播放器使用本地固定并扩展的 AudioStreaming 1.4.4，其 MIT 许可保留在 `Vendor/AudioStreaming/LICENSE`。其他原始版权及许可信息见 `LICENSE`、`NOTICE` 和 `COPYRIGHT`。
