# 0001. 以 Home Assistant 为唯一事实源并采用本地设备合成投影

MenuBarMijia 所有设备命名、房间归属与场景编排均以群晖 Home Assistant 为唯一事实源（Single Source of Truth）。macOS 客户端通过纯函数式的「设备合成（Device Synthesis）」将分散的底层实体（`HAEntityEntry` / `HAEntityState`）聚合为面向用户的逻辑设备（`SmartDevice`），本地仅持久化与当前 Mac 相关的视图偏好（`ViewPreference`：星标置顶、自定义排序、单设备隐藏、菜单栏展示指标）。这样可以彻底避免手机米家、HA 网页与 Mac 菜单栏之间出现多端配置分叉，同时让客户端状态层保持无副作用的单向数据流。
