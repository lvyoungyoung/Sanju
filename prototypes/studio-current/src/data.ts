export type Sentence = { id: string; memory: string; en: string; zh: string; group: number; blanks: number[]; topics: string[] };
export type Memory = { id: string; photo: string; date: string; label: string };
export type Topic = { id: string; name: string; sentences: string[]; mastery: number; created: number };
export const photos = [
  { id: 'cat', label: '草地上的小猫', src: '/photos/cat.png' },
  { id: 'hiking', label: '和朋友去徒步', src: '/photos/hiking.png' },
  { id: 'toddler', label: '孩子的小小世界', src: '/photos/toddler.png' },
];
export const initialMemories: Memory[] = [
  { id: 'm1', photo: 'cat', date: '2026年9月21日', label: '草地上的小猫' },
  { id: 'm2', photo: 'hiking', date: '2026年9月21日', label: '和朋友去徒步' },
  { id: 'm3', photo: 'toddler', date: '2026年9月20日', label: '孩子的小小世界' },
];
const rows: [string, string, number[], string[]][] = [
  ['A little kitten is walking through the grass.', '一只小猫正穿过草地。', [5, 7], ['宠物日常', '花草与动物']],
  ['The warm sunlight falls on its soft fur.', '温暖的阳光洒在它柔软的毛上。', [3, 4], ['宠物日常', '自然风景']],
  ['Its tiny paws are hidden in the green grass.', '它的小爪子藏在绿草里。', [4, 5], ['宠物日常']],
  ['This little one just made my day.', '这个小家伙让我一整天都开心了。', [3, 5], ['宠物日常']],
  ['I could watch this kitten all afternoon.', '我能看着这只小猫看一整个下午。', [2, 6], ['宠物日常']],
  ['A little sunshine makes everything feel better.', '一点阳光，就让一切变得更美好。', [3, 6], ['自然风景']],
  ['We are walking along a mountain trail.', '我们正沿着山间小路前行。', [2, 3], ['运动与户外', '自然风景']],
  ['A dog is following us up the hill.', '一只狗跟着我们往山上走。', [3, 5], ['宠物日常', '运动与户外']],
  ['Tall trees stand beside the quiet trail.', '高高的树木立在安静的小路旁。', [2, 3], ['自然风景', '花草与动物']],
  ['Fresh air and good company are all I need.', '新鲜空气和朋友相伴，就是我需要的。', [3, 8], ['朋友相聚', '运动与户外']],
  ['Nothing beats a walk in the mountains.', '没有什么比在山里走走更舒服了。', [1, 4], ['运动与户外']],
  ['I am glad we took the long way.', '真高兴我们选了那条远路。', [2, 4], ['旅行']],
  ['The little girl is holding a teddy bear.', '小女孩正抱着一只玩具熊。', [3, 4], ['孩子成长', '家人相处']],
  ['She is sitting on a colorful blanket.', '她坐在一张彩色的毯子上。', [2, 3], ['孩子成长', '居家']],
  ['Her favorite toy is never far away.', '她最喜欢的玩具总在身边。', [1, 5], ['孩子成长']],
  ['Some days, happiness is this simple.', '有时候，快乐就是这么简单。', [2, 5], ['孩子成长', '家人相处']],
  ['I wish I could keep this moment forever.', '真希望能把这一刻永远留下。', [3, 4], ['家人相处']],
  ['She takes her little friend everywhere.', '她走到哪儿都带着这个小伙伴。', [1, 5], ['孩子成长']],
];
export const initialSentences: Sentence[] = rows.map(([en, zh, blanks, topics], index) => ({ id: `s${index + 1}`, memory: `m${Math.floor(index / 6) + 1}`, en, zh, blanks, topics, group: index % 6 < 3 ? 0 : 1 }));
export const initialTopics: Topic[] = [
  { id: 't1', name: '在山里徒步', sentences: ['s7', 's8', 's9', 's10', 's11', 's12'], mastery: 33, created: 1 },
  { id: 't2', name: '宠物日常', sentences: ['s1', 's2', 's3', 's4', 's5', 's8'], mastery: 17, created: 2 },
  { id: 't3', name: '和孩子在一起', sentences: ['s13', 's14', 's15', 's16', 's17', 's18'], mastery: 0, created: 3 },
];
// Demo-only matching. This is not the production semantic search algorithm.
export function demoMatches(name: string, sentences: Sentence[]): string[] {
  const exact = sentences.filter(s => s.topics.includes(name));
  if (exact.length) return exact.map(s => s.id);
  const topic = /山|徒步|户外|hiking/i.test(name) ? '运动与户外' : /猫|狗|宠物|pet/i.test(name) ? '宠物日常' : /孩子|宝宝|成长|child/i.test(name) ? '孩子成长' : /朋友|友谊|friend/i.test(name) ? '朋友相聚' : /风景|自然|nature/i.test(name) ? '自然风景' : /家人|家|family/i.test(name) ? '家人相处' : '';
  return topic ? sentences.filter(s => s.topics.includes(topic)).map(s => s.id) : [];
}
