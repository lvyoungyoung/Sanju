# 生活场景主题

## 当前规则

预定义分类按用户相册中的生活场景划分，不再使用旧的 16 个宏观领域。分类对象是句子，不是照片。正常情况下每句 1-2 个不重复的分类：第一个是主场景，仅当句子本身明确涉及另一个独立场景时才加第二个，不强行凑数。没有适合场景的句子允许空数组，不强行增加“实用记录”或兜底分类。

| ID | 中文 | English |
| --- | --- | --- |
| `self_and_style` | 自己与穿搭 | Selfies & Style |
| `family_time` | 家人相处 | Family Time |
| `children_growing_up` | 孩子成长 | Kids Growing Up |
| `friends_gatherings` | 朋友相聚 | Time with Friends |
| `romance_and_companionship` | 恋爱与陪伴 | Love & Companionship |
| `pet_life` | 宠物日常 | Life with Pets |
| `food_and_drinks` | 吃喝 | Food & Drinks |
| `cooking` | 下厨 | Cooking |
| `home_life` | 居家 | At Home |
| `city_life` | 城市生活 | City Life |
| `natural_scenery` | 自然风景 | Nature & Scenery |
| `plants_and_wildlife` | 花草与动物 | Plants & Animals |
| `travel` | 旅行 | Travel |
| `transport` | 交通出行 | Getting Around |
| `sports_and_outdoors` | 运动与户外 | Sports & Outdoors |
| `festivals_and_celebrations` | 节日与庆祝 | Holidays & Celebrations |
| `arts_and_entertainment` | 文化娱乐 | Arts & Entertainment |
| `school_and_study` | 学校与学习 | School & Study |
| `work_life` | 工作 | Work |
| `shopping` | 购物 | Shopping |
| `health_and_wellness` | 身体与健康 | Health & Wellbeing |

同一张生日聚餐照，描述蛋糕味道的句子属于“吃喝”，描述庆生的句子属于“节日与庆祝”。“我们一家人去露营”可以同时属于“运动与户外”和“家人相处”，没有提到家人的露营句子则不添加“家人相处”。照片只能辅助消除歧义，不能把所有句子机械地归到照片的场景中。宠物和野生动物、吃喝和下厨、旅行和交通、普通聚会和庆祝等主场景边界已写入 MiMo/Kimi 共用的生成提示词。

## 匹配及客户端

- `LearningTopic.all` 是客户端的 21 个预定义主题，推荐标签和主题地图都使用这份目录；中英文文案已同步。
- 推荐仍从当前句子的已有分类里随机抽最多 3 个，不会凭空推荐没有内容的场景。
- 选择推荐主题，或手动输入与当前预定义名称完全匹配的名称，仍按稳定分类 ID 精确匹配。
- 自定义名称继续走向量初筛 + AI 复核，没有新增主题意图提取。
- 数据字段仍为 `learning_topic_ids`，最多两个值；生成、匿名恢复和数据库 JSON 解析会去重、保留主次顺序并截取前两个有效分类。不改变三句/六句响应格式、收藏、学习队列或生成扣次事务。同一句可进入两个分类主题，每个主题内仍只出现一次，学习进度仍按各主题独立记录。
- 图片级的 `tags` 是另外一套旧展示元数据，本次不改；不能把它与句子级分类混淆。

## 迁移与部署

用户明确不需要保留旧分类兼容。新增 `20260920001000_use_photo_life_scenes.sql`：

1. 删除旧预定义主题及其关联；不会删除自定义主题。
2. 清空已有句子的旧分类，不重新分类历史句子。
3. 不删除照片、句子、收藏或学习进度行。旧预定义主题的进度行保留在数据库，但不会自动转移给新主题；收藏和自定义主题进度保持原样。
4. 更新数据库分类白名单、JSON 解析函数和预定义主题创建 RPC，只接受新场景 ID。

先在 staging 应用 migration，再部署 `generate-memory-v2`、`recover-guest-generation`、`create-study-scene`，然后运行最新客户端并生成新照片验证。此次没有改动 `review-study-scene`。迁移和函数应协调部署，避免旧函数仍生成已退役的分类；旧内部测试客户端/缓存不在分类兼容范围内。没有主题功能的 production 客户端依旧使用原响应字段，但需在 staging 完成其兼容性检查后再发布后端。

## 自动检查与人工验证

- `deno test --no-lock --allow-read --allow-env scripts/tests/`
- `bash scripts/check-edge-functions.sh`
- iOS simulator build/test，包含 `LearningTopicsTests`。
- 自动测试核对客户端、数据库和三个函数的全部 ID 一致，中英文标题可创建；检查无分类句子不被丢弃、匿名恢复和客户端持久化保留两个分类、重复和第三个分类被过滤、数据库拒绝三个分类、同一句可进入两个主题且刷新不重复、同图句子可进不同主题。
- 本地 PostgreSQL 测试检查迁移保留照片、收藏、自定义主题及学习历史，分类主题不走语义审核，跨账号不能混入句子。
- staging 人工测试聚餐/生日、宠物、做饭/成品食物、旅行/交通、普通截图，并检查两组句子分类是否合理。自动测试不证明模型实际分类质量。
