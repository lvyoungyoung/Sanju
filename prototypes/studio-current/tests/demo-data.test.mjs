import assert from 'node:assert/strict';
import { test } from 'node:test';
import { existsSync } from 'node:fs';
import { demoMatches, initialMemories, initialSentences, initialTopics, photos } from '../src/data.ts';

test('every sample memory contains two groups of three sentences', () => {
  for (const memory of initialMemories) {
    for (const group of [0, 1]) assert.equal(initialSentences.filter(s => s.memory === memory.id && s.group === group).length, 3);
  }
});
test('IDs are unique and sentence references are valid', () => {
  assert.equal(new Set(initialSentences.map(s => s.id)).size, initialSentences.length);
  for (const sentence of initialSentences) assert.ok(initialMemories.some(m => m.id === sentence.memory));
  for (const topic of initialTopics) for (const id of topic.sentences) assert.ok(initialSentences.some(s => s.id === id));
});
test('all sample blank positions are valid and unique', () => {
  for (const sentence of initialSentences) {
    assert.equal(new Set(sentence.blanks).size, sentence.blanks.length);
    for (const index of sentence.blanks) assert.ok(sentence.en.split(' ')[index]);
  }
});
test('recommended categories match exact category labels', () => {
  const matches = demoMatches('宠物日常', initialSentences);
  assert.ok(matches.includes('s1'));
  assert.ok(matches.includes('s8'));
  assert.ok(!matches.includes('s13'));
});
test('unmatched demo topic returns a valid empty list', () => {
  assert.deepEqual(demoMatches('在咖啡馆吃早餐', initialSentences), []);
});
test('local photo assets are present', () => {
  for (const photo of photos) assert.ok(existsSync(new URL('../public' + photo.src, import.meta.url)));
  assert.ok(existsSync(new URL('../public/photos/collage.png', import.meta.url)));
});
