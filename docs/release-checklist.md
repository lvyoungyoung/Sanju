# 发布检查清单

## 后端环境变量

- 正式环境确认 `GENERATION_VIOLATION_BAN_ENABLED=true`，开启“连续违规图片会临时禁用生成”的保护。代码默认开启；只有显式设为 `false` 才会关闭。
- 测试期间如需临时关闭，可设 `GENERATION_VIOLATION_BAN_ENABLED=false`，这样单张违规图片仍会被拦截，但不会累计违规次数，也不会受已有封禁时间影响。
- 上线前确认 `IMAGE_MODERATION_DEBUG=false`，避免把图片审核失败详情返回给客户端。
