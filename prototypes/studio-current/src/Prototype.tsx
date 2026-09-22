import { useEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { ArrowLeftIcon, ArrowRightIcon, BookmarkIcon, CheckIcon, ChevronRightIcon, Cross2Icon, DotsHorizontalIcon, GearIcon, ImageIcon, Pencil1Icon, PersonIcon, PlusIcon, ReaderIcon, ReloadIcon, SpeakerLoudIcon, StarFilledIcon, StarIcon, TrashIcon } from '@radix-ui/react-icons';
import { BottomSheet, KeyboardInput, MobileScroll, useKeyboard, useKeyboardInsets } from './mobile';
import { demoMatches, initialMemories, initialSentences, initialTopics, photos, type Memory, type Sentence, type Topic } from './data';

type Tab = 'new' | 'memories' | 'study' | 'profile';
type Route = { kind: 'root' } | { kind: 'memory'; id: string } | { kind: 'topic'; id: string } | { kind: 'about' } | { kind: 'exercise' | 'complete' };
type Session = { ids: string[]; scope: string; index: number; filled: number[]; active: number; wrong: boolean; origin: Route; reviewing: boolean };
type Sheet = { type: string; id?: string } | null;
const terms = <><a href="https://sanju.cc/terms.html" target="_blank" rel="noreferrer">用户服务协议</a><span>和</span><a href="https://sanju.cc/privacy.html" target="_blank" rel="noreferrer">隐私协议</a></>;
function IconButton({ label, onClick, children, disabled = false }: { label: string; onClick: () => void; children: ReactNode; disabled?: boolean }) {
  return <button className="icon-button" aria-label={label} onClick={onClick} disabled={disabled}>{children}</button>;
}
function Spinner() { return <span className="spinner" role="status" aria-label="正在加载" />; }
function ContextTarget({ children, onOpen }: { children: ReactNode; onOpen: () => void }) {
  const press = useRef<{ timer: number; x: number; y: number; fired: boolean } | null>(null);
  const clear = () => { if (press.current) window.clearTimeout(press.current.timer); };
  useEffect(() => clear, []);
  return <div onContextMenu={e => { e.preventDefault(); onOpen(); }} onKeyDown={e => { if (e.key === 'F10' && e.shiftKey) { e.preventDefault(); onOpen(); } }} onPointerDown={e => { if (e.button !== 0) return; press.current = { x: e.clientX, y: e.clientY, fired: false, timer: window.setTimeout(() => { if (press.current) press.current.fired = true; onOpen(); }, 650) }; }} onPointerMove={e => { if (press.current && Math.hypot(e.clientX - press.current.x, e.clientY - press.current.y) > 8) clear(); }} onPointerCancel={clear} onPointerUp={clear} onClickCapture={e => { if (press.current?.fired) { e.stopPropagation(); e.preventDefault(); press.current.fired = false; } }}>{children}</div>;
}

export default function Prototype() {
  const keyboard = useKeyboard();
  const { bottomInset } = useKeyboardInsets();
  const [tab, setTab] = useState<Tab>('new');
  const [route, setRoute] = useState<Route>({ kind: 'root' });
  const [sheet, setSheet] = useState<Sheet>(null);
  const [signedIn, setSignedIn] = useState(true);
  const [online, setOnline] = useState(true);
  const [memories, setMemories] = useState<Memory[]>(initialMemories);
  const [sentences, setSentences] = useState<Sentence[]>(initialSentences);
  const [topics, setTopics] = useState<Topic[]>(initialTopics);
  const [favorites, setFavorites] = useState(['s1', 's4', 's7', 's13']);
  const [counts, setCounts] = useState<Record<string, number>>({ 'favorites:s4': 3, 'favorites:s1': 1, 't1:s7': 2, 't1:s9': 3 });
  const [today, setToday] = useState<Record<string, string[]>>({ favorites: ['s4'], t1: [], t2: [], t3: [] });
  const [selectedPhoto, setSelectedPhoto] = useState<string | null>(null);
  const [newState, setNewState] = useState<'empty' | 'reading' | 'preview' | 'generating' | 'result' | 'recovery'>('empty');
  const [resultID, setResultID] = useState('m1');
  const [group, setGroup] = useState(0);
  const [credits, setCredits] = useState(24);
  const [purchased, setPurchased] = useState(false);
  const [nickname, setNickname] = useState('小满');
  const [difficulty, setDifficulty] = useState('初级');
  const [style, setStyle] = useState('平铺直叙');
  const [reminder, setReminder] = useState(false);
  const [reminderTime, setReminderTime] = useState('20:00');
  const [autoSpeak, setAutoSpeak] = useState(() => { try { return localStorage.getItem('sanju-studio-current-auto-speak') !== 'false'; } catch { return true; } });
  const [draft, setDraft] = useState('');
  const [selectedTag, setSelectedTag] = useState('');
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const [topicLoading, setTopicLoading] = useState<string | null>(null);
  const [slow, setSlow] = useState(false);
  const [session, setSession] = useState<Session | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [toast, setToast] = useState('');
  const [authMode, setAuthMode] = useState('login');
  const [authEmail, setAuthEmail] = useState('demo@example.com');
  const [authPassword, setAuthPassword] = useState('demo123');
  const [showPassword, setShowPassword] = useState(false);
  const [purchaseSize, setPurchaseSize] = useState(200);
  const [pageOpacity, setPageOpacity] = useState(1);
  const pageRef = useRef<HTMLDivElement>(null);
  const timers = useRef<number[]>([]);
  const prefChanges = useRef<number[]>([]);
  const prefBlockedUntil = useRef(0);
  const pull = useRef<{ y: number; can: boolean; distance: number } | null>(null);
  const root = route.kind === 'root';
  const navVisible = root || route.kind === 'about';
  const studyActive = route.kind === 'exercise' || route.kind === 'complete';
  const after = (fn: () => void, ms: number) => { const id = window.setTimeout(fn, ms); timers.current.push(id); return id; };
  useEffect(() => () => { timers.current.forEach(clearTimeout); window.speechSynthesis?.cancel(); }, []);
  useEffect(() => { if (!toast) return; const id = window.setTimeout(() => setToast(''), 2800); return () => clearTimeout(id); }, [toast]);
  useEffect(() => { const el = pageRef.current?.querySelector('.mobile-scroll'); if (el) el.scrollTop = 0; setPageOpacity(1); }, [tab, route.kind, 'id' in route ? route.id : '', session?.index]);
  useEffect(() => { if (!topicLoading) return; setSlow(false); const id = window.setTimeout(() => setSlow(true), 5000); return () => clearTimeout(id); }, [topicLoading]);
  const open = (next: Sheet) => { keyboard.hide(); setSheet(next); };
  const close = () => { keyboard.hide(); setSheet(null); };
  const go = (next: Route) => { keyboard.hide(); setRoute(next); };
  const switchTab = (next: Tab) => { keyboard.hide(); setSheet(null); setRefreshing(false); setToast(''); setTab(next); setRoute({ kind: 'root' }); };
  const getPhoto = (memoryID: string) => photos.find(p => p.id === memories.find(m => m.id === memoryID)?.photo) ?? photos[0];
  const scopeIDs = (scope: string) => scope === 'favorites' ? favorites : topics.find(t => t.id === scope)?.sentences ?? [];
  const studied = (scope: string) => (today[scope] ?? []).filter(id => scopeIDs(scope).includes(id));
  const due = (scope: string) => scopeIDs(scope).filter(id => !studied(scope).includes(id));
  function speak(text: string) {
    if (!('speechSynthesis' in window)) { setToast('当前浏览器不支持朗读。'); return; }
    const voice = window.speechSynthesis.getVoices().find(v => v.localService && /^en[-_]/i.test(v.lang));
    if (!voice) { setToast('当前浏览器没有可用的本地英语声音。'); return; }
    window.speechSynthesis.cancel(); const utterance = new SpeechSynthesisUtterance(text); utterance.voice = voice; utterance.rate = .9;
    utterance.onerror = () => setToast('朗读暂时不可用，请稍后再试。'); window.speechSynthesis.speak(utterance);
  }
  function toggleFavorite(id: string) { setFavorites(current => current.includes(id) ? current.filter(s => s !== id) : [...current, id]); }
  function choosePhoto(photo: string) { close(); setSelectedPhoto(photo); setGroup(0); setNewState('reading'); after(() => setNewState('preview'), 700); }
  function finishGeneration() {
    const sourceMemory = initialMemories.find(m => m.photo === (selectedPhoto ?? 'cat'))!;
    const memoryID = `m${Date.now()}`;
    const added = initialSentences.filter(s => s.memory === sourceMemory.id).map(s => ({ ...s, memory: memoryID, id: `${memoryID}-${s.id}` }));
    setMemories(current => [{ ...sourceMemory, id: memoryID, date: '2026年9月21日' }, ...current]); setSentences(current => [...current, ...added]);
    setTopics(current => current.map(t => ({ ...t, sentences: [...t.sentences, ...demoMatches(t.name, added)] })));
    setCredits(c => Math.max(0, c - 1)); setResultID(memoryID); setGroup(0); setNewState('result');
  }
  function generate() {
    if (!online) { setToast('当前网络不可用，请连接网络后再试。'); return; }
    if (credits < 1) { open({ type: 'purchase' }); return; }
    setNewState('generating'); after(finishGeneration, 1800);
  }
  function refresh() { if (refreshing) return; setRefreshing(true); after(() => setRefreshing(false), 1300); }
  function randomSuggestions() { setSuggestions([...new Set(sentences.flatMap(s => s.topics))].map(value => ({ value, random: Math.random() })).sort((a, b) => a.random - b.random).slice(0, 3).map(x => x.value)); }
  function createTopic() {
    if (!signedIn) { setAuthMode('login'); open({ type: 'login' }); return; }
    if (topics.length >= 20) { setToast('最多可以创建20个学习主题'); return; }
    setDraft(''); setSelectedTag(''); randomSuggestions(); open({ type: 'create' });
  }
  function submitTopic() {
    const name = (selectedTag || draft).trim(); if (!name) return;
    if (!online) { setToast('当前网络不可用，请连接网络后再试。'); return; }
    const id = `topic${Date.now()}`;
    setTopics(current => [...current, { id, name, sentences: [], mastery: 0, created: Date.now() }]);
    close(); go({ kind: 'topic', id }); setTopicLoading(id);
    after(() => { setTopics(current => current.map(t => t.id === id ? { ...t, sentences: demoMatches(name, sentences) } : t)); setTopicLoading(null); }, 2100);
  }
  function startStudy(scope: string, forceReview = false) {
    const reviewing = forceReview || due(scope).length === 0;
    const ids = reviewing ? studied(scope) : due(scope); if (!ids.length) return;
    setSession({ ids, scope, index: 0, filled: [], active: 0, wrong: false, origin: route.kind === 'complete' ? session?.origin ?? { kind: 'root' } : route, reviewing }); go({ kind: 'exercise' });
  }
  function answer(wordIndex: number) {
    if (!session) return; const sentence = sentences.find(s => s.id === session.ids[session.index])!;
    const words = sentence.en.split(' '); const target = sentence.blanks[session.active];
    if (words[wordIndex] !== words[target]) { setSession({ ...session, wrong: true }); after(() => setSession(s => s ? { ...s, wrong: false } : s), 400); return; }
    const filled = [...session.filled, target], next = sentence.blanks.findIndex(index => !filled.includes(index));
    setSession({ ...session, filled, active: Math.max(0, next), wrong: false });
    if (next === -1) {
      if (!studied(session.scope).includes(sentence.id)) {
        setToday(current => ({ ...current, [session.scope]: [...(current[session.scope] ?? []), sentence.id] }));
        setCounts(current => ({ ...current, [`${session.scope}:${sentence.id}`]: (current[`${session.scope}:${sentence.id}`] ?? 0) + 1 }));
      }
      if (autoSpeak) speak(sentence.en);
    }
  }
  function nextQuestion() { if (!session) return; window.speechSynthesis?.cancel(); if (session.index === session.ids.length - 1) go({ kind: 'complete' }); else setSession({ ...session, index: session.index + 1, filled: [], active: 0, wrong: false }); }
  function leaveStudy() { window.speechSynthesis?.cancel(); go(session?.origin ?? { kind: 'root' }); }
  function changePreference(value: string, kind: 'level' | 'style') {
    const now = Date.now(); prefChanges.current = prefChanges.current.filter(time => now - time < 60000);
    if (now < prefBlockedUntil.current || prefChanges.current.length >= 10) { if (prefBlockedUntil.current < now) prefBlockedUntil.current = now + 300000; setToast('操作频繁，请稍后再试。'); return; }
    prefChanges.current.push(now); if (kind === 'level') { setDifficulty(value); if (value === '启蒙') setStyle('平铺直叙'); } else setStyle(value);
  }
  function deleteMemory(id: string) {
    const removed = new Set(sentences.filter(s => s.memory === id).map(s => s.id));
    setMemories(current => current.filter(m => m.id !== id)); setSentences(current => current.filter(s => !removed.has(s.id)));
    setFavorites(current => current.filter(s => !removed.has(s))); setTopics(current => current.map(t => ({ ...t, sentences: t.sentences.filter(s => !removed.has(s)) })));
    if (id === resultID) { setSelectedPhoto(null); setNewState('empty'); }
    close(); go({ kind: 'root' }); setToast('已删除回忆');
  }
  function overview(scope: string) {
    const waiting = due(scope).length, done = studied(scope).length;
    return <section className="overview"><div className="overview-counts"><div><span>今日待学</span><strong>{waiting}<small>句</small></strong></div><i /><div><span>今日已学</span><strong>{done}<small>句</small></strong></div></div><button className="primary" disabled={!waiting && !done} onClick={() => startStudy(scope)}>{waiting ? '开始学习' : done ? '再学一遍' : '今天学完了'}<ArrowRightIcon /></button></section>;
  }
  function sentenceGroups(memoryID: string) {
    const list = sentences.filter(s => s.memory === memoryID && s.group === group);
    return <><div className="segment groups" role="tablist" aria-label="句子类型">{['画面描述', '生活表达'].map((label, index) => <button key={label} role="tab" aria-selected={group === index} aria-controls="sentence-panel" onClick={() => setGroup(index)}>{label}</button>)}</div><div id="sentence-panel" role="tabpanel" aria-label={group === 0 ? '画面描述' : '生活表达'}>{list.length ? list.map((s, index) => <article className="sentence-result" key={s.id}><span className="number">0{index + 1}</span><p className="english">{s.en}</p><p className="translation">{s.zh}</p><div className="sentence-actions"><button onClick={() => speak(s.en)}><SpeakerLoudIcon />播放</button><button aria-pressed={favorites.includes(s.id)} onClick={() => toggleFavorite(s.id)}>{favorites.includes(s.id) ? <StarFilledIcon /> : <StarIcon />}收藏</button></div></article>) : <div className="empty compact">没有内容</div>}</div></>;
  }
  function topicRows() {
    return <div className="topic-list">{topics.map(topic => {
      const oldest = memories.slice().reverse().find(m => sentences.some(s => s.memory === m.id && topic.sentences.includes(s.id)));
      return <ContextTarget key={topic.id} onOpen={() => open({ type: 'deleteTopic', id: topic.id })}><button className="topic-card" onClick={() => go({ kind: 'topic', id: topic.id })}><div className="topic-copy"><h3>{topic.name}</h3><span>共 {topic.sentences.length} 句</span><div className="mastery" role="progressbar" aria-label={`${topic.name}掌握度`} aria-valuenow={topic.mastery} aria-valuemin={0} aria-valuemax={100}><i style={{ width: `${topic.mastery}%` }} /></div></div>{oldest ? <img src={getPhoto(oldest.id).src} alt="" /> : <div className="topic-no-photo"><ReaderIcon /></div>}</button></ContextTarget>;
    })}</div>;
  }
  function newPage() {
    const photo = photos.find(p => p.id === selectedPhoto) ?? photos[0];
    if (newState === 'empty') return <div className="new-empty"><div className="new-brand"><span>三句</span><span className="eyebrow">LITTLE BY LITTLE</span></div><img className="collage" src="/photos/collage.png" alt="生活照片与英语句子的拼贴" /><h1>选一张你愿意记住的画面，<br />用它来学会一句英语。</h1><div className="new-bottom"><button className="primary" disabled={!online} onClick={() => open({ type: 'picker' })}><PlusIcon />{online ? '点击选择图片' : '请连接网络'}<ArrowRightIcon /></button><p className="fineprint">图片会被发送给 AI 分析，<br />请勿上传包含敏感信息的图片</p><div className="legal">{terms}</div></div></div>;
    if (newState === 'reading') return <div className="empty reading"><Spinner /><h2>正在读取照片...</h2><p>如果本地没有原图，<br />从 iCloud 获取图片会花点时间。</p></div>;
    return <><div className="photo-frame"><img src={photo.src} alt={photo.label} />{newState === 'preview' && <IconButton label="移除已选照片" onClick={() => { setSelectedPhoto(null); setNewState('empty'); }}><Cross2Icon /></IconButton>}</div>{newState === 'preview' && <div className="generate-actions"><button className="primary" onClick={generate}>用三句描述一下<ArrowRightIcon /></button><p className="caption">剩余可用次数：{credits}</p><p className="caption">生成后自动保存到回忆</p></div>}{newState === 'generating' && <div className="generation"><Spinner /><h2>正在理解画面</h2><p>正在把这一刻，变成可以学习的句子。</p><div className="skeleton" /><div className="skeleton short" /></div>}{newState === 'recovery' && <div className="generation"><h2>{online ? '暂未从云端获取到结果' : '当前网络不可用'}</h2><p>{online ? '不会重新生成，只会尝试获取刚才那次生成的结果。' : '请连接网络后获取结果。网络恢复后会自动尝试获取结果。'}</p><button className="primary" disabled={!online} onClick={() => { setNewState('generating'); after(finishGeneration, 1200); }}>重新获取结果</button><button className="text-button" onClick={() => setNewState('preview')}>放弃本次恢复</button></div>}{newState === 'result' && <>{sentenceGroups(resultID)}<p className="result-hint">内容已生成，建议收藏 1 到 2 句反复学习。</p><button className="primary" disabled={!online} onClick={() => open({ type: 'picker' })}>再来一张<PlusIcon /></button></>}</>;
  }
  function memoriesPage() {
    return <><h1 className="page-title" style={{ opacity: pageOpacity }}>回忆</h1>{!memories.length ? <div className="empty"><ImageIcon /><h2>还没有回忆</h2><p>选择一张生活中的照片，<br />生成的内容会保存在这里。</p></div> : [...new Set(memories.map(m => m.date))].map(date => <section className="memory-section" key={date}><h2 className="date-heading">{date}</h2><div className="memory-grid">{memories.filter(m => m.date === date).map(m => <ContextTarget key={m.id} onOpen={() => open({ type: 'deleteMemory', id: m.id })}><button className="memory-tile" aria-label={`查看${m.label}`} onClick={() => { setGroup(0); go({ kind: 'memory', id: m.id }); }}><img src={getPhoto(m.id).src} alt={m.label} /></button></ContextTarget>)}</div></section>)}</>;
  }
  function studyPage() {
    return <><h1 className="page-title" style={{ opacity: pageOpacity }}>学习</h1><div className="section-heading"><h2>收藏</h2><button className="text-button" onClick={() => go({ kind: 'topic', id: 'favorites' })}>查看全部<ChevronRightIcon /></button></div>{overview('favorites')}<div className="section-heading themes-heading"><h2>我的学习主题</h2></div>{topics.length ? topicRows() : <div className="empty topics-empty"><ReaderIcon /><p>创建一个学习主题，集中练习相关句子。<br />比如「和朋友聚餐」或「海边度假」。</p></div>}<button className="create-button" onClick={createTopic}><PlusIcon />创建我的学习主题</button></>;
  }
  function topicDetail(id: string) {
    const list = scopeIDs(id).map(sid => sentences.find(s => s.id === sid)).filter((s): s is Sentence => !!s);
    if (topicLoading === id) return <div className="empty matching"><Spinner /><h2>正在寻找这个主题的句子</h2><p>{slow ? '首次寻找主题下的句子可能耗时较长，请稍后' : '马上就好，正在整理相关表达'}</p></div>;
    return <>{overview(id)}<div className="sentence-list">{list.length ? list.map(s => <ContextTarget key={s.id} onOpen={() => id === 'favorites' && open({ type: 'unfavorite', id: s.id })}><article className="study-sentence" tabIndex={id === 'favorites' ? 0 : undefined}><div className="sentence-top"><p className="english">{s.en}</p><IconButton label={`朗读：${s.en}`} onClick={() => speak(s.en)}><SpeakerLoudIcon /></IconButton></div><p className="translation">{s.zh}</p><footer><time>{memories.find(m => m.id === s.memory)?.date}</time><span>已学 {counts[`${id}:${s.id}`] ?? 0} 次</span></footer></article></ContextTarget>) : <div className="empty"><BookmarkIcon /><h2>{id === 'favorites' ? '还没有收藏的句子' : '暂未找到匹配句子'}</h2><p>{id === 'favorites' ? '收藏你想记住的句子，随时回来学习。' : '以后生成相关画面时，它们会自动出现在这里。'}</p></div>}</div></>;
  }
  function profilePage() {
    return <><section className={`profile-hero ${signedIn ? '' : 'guest'}`}><div className="avatar"><PersonIcon /></div><div className="profile-name"><h1>{signedIn ? nickname : '未登录'}</h1>{signedIn && <span>demo@example.com</span>}</div>{signedIn ? <IconButton label="修改昵称" onClick={() => { setDraft(nickname); open({ type: 'nickname' }); }}><Pencil1Icon /></IconButton> : <button className="login-button" onClick={() => { if (newState === 'generating') setToast('正在为您生成描述，请稍后操作。'); else { setAuthMode('login'); open({ type: 'login' }); } }}>登录</button>}</section>{!signedIn && purchased && <p className="warning">请尽快登录，以免换设备时丢失您购买的可用次数。</p>}<section className="credits-card"><div><span>可用次数</span><strong>{credits}</strong></div><button className="small-primary" onClick={() => open({ type: 'purchase' })}>购买次数</button></section><h2 className="settings-heading">生成偏好</h2><section className="settings-card"><h3>难度</h3><div className="segment levels">{['启蒙', '初级', '中级', '高级'].map(level => <button key={level} aria-pressed={difficulty === level} onClick={() => changePreference(level, 'level')}>{level}</button>)}</div><h3>语言风格</h3><div className="segment">{['平铺直叙', '抒情优雅'].map(value => <button key={value} disabled={difficulty === '启蒙' && value === '抒情优雅'} aria-pressed={style === value} onClick={() => changePreference(value, 'style')}>{value}</button>)}</div></section><h2 className="settings-heading">桌面小组件</h2><button className="settings-card setting-link" onClick={() => open({ type: 'widget' })}><div><h3>添加桌面小组件</h3><p>把随机回忆放到桌面，<br />点开就能继续学习。</p></div><ChevronRightIcon /></button><h2 className="settings-heading">学习提醒</h2><section className="settings-card reminder"><button role="switch" aria-label="学习提醒" aria-checked={reminder} className="switch" onClick={() => setReminder(!reminder)}><span /></button>{reminder && <button className="time-pill" onClick={() => { setDraft(reminderTime); open({ type: 'reminder' }); }}>{reminderTime}</button>}</section><h2 className="settings-heading">关于</h2><button className="settings-card setting-link" onClick={() => go({ kind: 'about' })}><h3>关于我们</h3><ChevronRightIcon /></button>{signedIn && <><h2 className="settings-heading">账户</h2><button className="settings-card account-link" onClick={() => newState === 'generating' ? setToast('正在为您生成描述，请稍后操作。') : open({ type: 'logout' })}>退出登录</button><button className="settings-card account-link muted" onClick={() => { setDraft(''); open({ type: 'deleteAccount' }); }}>删除账号</button></>}</>;
  }
  function exercisePage() {
    if (!session) return null; const sentence = sentences.find(s => s.id === session.ids[session.index])!;
    const complete = session.filled.length === sentence.blanks.length;
    return <><div className="question-prompt"><img src={getPhoto(sentence.memory).src} alt="句子对应的画面" /><p>{sentence.zh}</p></div><div className={`question-words ${session.wrong ? 'wrong' : ''}`}>{sentence.en.split(' ').map((word, index) => sentence.blanks.includes(index) ? <button key={index} className={`blank ${session.filled.includes(index) ? 'filled' : session.active === sentence.blanks.indexOf(index) ? 'active' : ''}`} aria-label={session.filled.includes(index) ? word : `空格 ${sentence.blanks.indexOf(index) + 1}`} onClick={() => !session.filled.includes(index) && setSession({ ...session, active: sentence.blanks.indexOf(index) })}>{session.filled.includes(index) ? word : ' '}</button> : <span key={index}>{word}</span>)}</div>{!complete ? <><p className="question-hint">点击对应的单词，填写到高亮的空格中。</p><div className="word-bank">{sentence.blanks.slice().reverse().filter(index => !session.filled.includes(index)).map(index => <button key={index} onClick={() => answer(index)}>{sentence.en.split(' ')[index]}</button>)}</div></> : <div className="solved"><span><CheckIcon />填空完成</span><button className="secondary" onClick={() => speak(sentence.en)}><SpeakerLoudIcon />朗读句子</button><button className="primary" onClick={nextQuestion}>下一句<ArrowRightIcon /></button></div>}</>;
  }
  const title = route.kind === 'memory' ? '详情' : route.kind === 'topic' ? route.id === 'favorites' ? `收藏（${favorites.length}）` : topics.find(t => t.id === route.id)?.name : route.kind === 'about' ? '关于我们' : '';
  const sheetTitle: Record<string, string> = { picker: '选择照片', create: '创建我的学习主题', settings: '学习设置', nickname: '修改昵称', purchase: '购买次数', widget: '添加桌面小组件', reminder: '选择提醒时间', login: authMode === 'login' ? '邮箱登录' : authMode === 'signup' ? '注册账号' : '重置密码', logout: '确定要退出登录吗？', deleteAccount: '删除账号', deleteTopic: '删除这个学习主题？', deleteMemory: '删除这条回忆？', unfavorite: '取消收藏', memoryMenu: '回忆操作', export: '保存到本地' };
  return <>
    {createPortal(<aside className="review-panel"><p className="review-kicker">SANJU / DESIGN STUDY 03</p><h1>轻盈学习<br /><span>现有功能版</span></h1><p>保留现在的使用方式，<br />只换一种更轻盈的表达。</p><div className="review-sections">{(['new', 'memories', 'study', 'profile'] as Tab[]).map((key, index) => <button key={key} aria-pressed={tab === key} onClick={() => switchTab(key)}><small>0{index + 1}</small>{['新的', '回忆', '学习', '我的'][index]}<ArrowRightIcon /></button>)}</div><details><summary>原型状态切换</summary><div className="demo-controls"><button onClick={() => { setSignedIn(!signedIn); switchTab('profile'); }}>{signedIn ? '切换为未登录' : '切换为已登录'}</button><button onClick={() => { const next = !online; setOnline(next); if (next && newState === 'recovery') { setNewState('generating'); after(finishGeneration, 1200); } }}>{online ? '模拟无网络' : '恢复网络'}</button><button onClick={() => { switchTab('new'); setSelectedPhoto('cat'); setNewState('recovery'); }}>查看结果恢复状态</button><button onClick={() => { setTopics([]); switchTab('study'); }}>查看主题空状态</button><button onClick={() => { timers.current.forEach(clearTimeout); setTopics(initialTopics); setMemories(initialMemories); setSentences(initialSentences); setFavorites(['s1', 's4', 's7', 's13']); setToday({ favorites: ['s4'] }); setCounts({ 'favorites:s4': 3 }); setCredits(24); setNewState('empty'); setSelectedPhoto(null); setTopicLoading(null); switchTab('new'); }}>重置演示</button><button onClick={refresh}>模拟下拉刷新</button></div></details><p className="review-note">可点击体验 · 演示数据<br />不连接后台，不产生真实购买。<br />长按卡片或右键可查看菜单。</p><a className="compare-link" href="http://127.0.0.1:8765/03-studio/" target="_blank" rel="noreferrer">对照原方案 3</a></aside>, document.body)}
    <div ref={pageRef} className={`sanju-app ${navVisible ? 'has-nav' : ''} ${studyActive ? 'study-active' : ''}`} onScrollCapture={e => { if ((e.target as HTMLElement).classList.contains('mobile-scroll')) setPageOpacity(Math.max(0, 1 - (e.target as HTMLElement).scrollTop / 70)); }} onPointerDownCapture={e => { const scroll = pageRef.current?.querySelector('.mobile-scroll'); pull.current = { y: e.clientY, can: (scroll?.scrollTop ?? 0) < 2 && signedIn && ((root && (tab === 'study' || tab === 'memories')) || route.kind === 'topic'), distance: 0 }; }} onPointerMoveCapture={e => { if (pull.current?.can) pull.current.distance = e.clientY - pull.current.y; }} onPointerUpCapture={() => { if (pull.current?.can && pull.current.distance > 85) refresh(); pull.current = null; }}>
      {!root && !studyActive && <header className="detail-header"><IconButton label="返回" onClick={() => go({ kind: 'root' })}><ArrowLeftIcon /></IconButton><h1>{title}</h1>{route.kind === 'memory' ? <IconButton label="更多操作" onClick={() => open({ type: 'memoryMenu', id: route.id })}><DotsHorizontalIcon /></IconButton> : <span className="header-spacer" />}</header>}
      {studyActive && <header className="detail-header exercise-header"><IconButton label="关闭学习" onClick={leaveStudy}><Cross2Icon /></IconButton>{route.kind === 'exercise' && <span className="session-pill">{session?.reviewing ? '再练句子' : '学习句子'} {session!.index + 1}/{session!.ids.length}</span>}</header>}
      <MobileScroll className={root ? 'root-scroll' : 'detail-scroll'}><main className={`page-content ${root && tab === 'new' && newState === 'empty' ? 'landing-content' : ''}`}>
        {refreshing && <div className="refresh-indicator"><Spinner /></div>}
        {root && (tab === 'new' ? newPage() : tab === 'memories' ? memoriesPage() : tab === 'study' ? studyPage() : profilePage())}
        {route.kind === 'topic' && topicDetail(route.id)}
        {route.kind === 'memory' && <><div className="photo-frame"><img src={getPhoto(route.id).src} alt={memories.find(m => m.id === route.id)?.label} /></div>{sentenceGroups(route.id)}</>}
        {route.kind === 'about' && <div className="about-list"><section className="settings-card"><span>运营主体</span><strong>三言信息智能</strong></section><section className="settings-card"><span>备案号</span><strong>苏ICP备2026022269号-2A</strong></section><a className="settings-card setting-link" href="https://sanju.cc/terms.html" target="_blank" rel="noreferrer">用户服务协议<ChevronRightIcon /></a><a className="settings-card setting-link" href="https://sanju.cc/privacy.html" target="_blank" rel="noreferrer">隐私协议<ChevronRightIcon /></a></div>}
        {route.kind === 'exercise' && exercisePage()}
        {route.kind === 'complete' && <div className="completion"><div className="completion-icon"><CheckIcon /></div><h1>你已完成学习</h1><p>今天已经学习了 {studied(session!.scope).length} 句</p><button className="secondary" onClick={() => startStudy(session!.scope, true)}>再学习一遍</button><button className="primary" onClick={leaveStudy}>返回</button><p className="completion-reminder">{reminder ? `你已开启定时提醒，将在每天${reminderTime}提醒你学习` : '你可以在设置中开启定时提醒，每天提醒你学习。'}</p></div>}
      </main></MobileScroll>
      {navVisible && <nav className="bottom-nav" aria-label="主要导航">{([{ key: 'new', label: '新的', Icon: PlusIcon }, { key: 'memories', label: '回忆', Icon: ImageIcon }, { key: 'study', label: '学习', Icon: ReaderIcon }, { key: 'profile', label: '我的', Icon: PersonIcon }] as const).map(({ key, label, Icon }) => <button key={key} aria-current={tab === key ? 'page' : undefined} onClick={() => switchTab(key)}><Icon /><span>{label}</span></button>)}</nav>}
      {route.kind === 'memory' && <div className="memory-pager"><IconButton label="上一张" disabled={memories.findIndex(m => m.id === route.id) === 0} onClick={() => { setGroup(0); go({ kind: 'memory', id: memories[memories.findIndex(m => m.id === route.id) - 1].id }); }}><ArrowLeftIcon /></IconButton><IconButton label="下一张" disabled={memories.findIndex(m => m.id === route.id) >= memories.length - 1} onClick={() => { setGroup(0); go({ kind: 'memory', id: memories[memories.findIndex(m => m.id === route.id) + 1].id }); }}><ArrowRightIcon /></IconButton></div>}
      {route.kind === 'exercise' && <div className="study-settings"><IconButton label="学习设置" onClick={() => open({ type: 'settings' })}><GearIcon /></IconButton></div>}
      {toast && <div className="toast" role="status" style={{ bottom: bottomInset + (navVisible ? 90 : 60) }}>{toast}</div>}
    </div>
    <BottomSheet open={!!sheet} onOpenChange={isOpen => !isOpen && close()} title={sheetTitle[sheet?.type ?? ''] ?? ''} description={sheet?.type === 'picker' ? '系统相册的原型占位，仅提供三张演示照片。' : sheet?.type === 'login' || sheet?.type === 'purchase' ? '原型演示，不会发送个人信息或发起真实交易。' : undefined} snap={sheet?.type === 'widget' || sheet?.type === 'login' ? .8 : sheet?.type === 'purchase' ? .62 : sheet?.type === 'create' ? .43 : .4}>
      <div className={`sheet-inner sheet-${sheet?.type ?? 'closed'}`}>
        {sheet?.type === 'picker' && <div className="picker-grid">{photos.map(photo => <button key={photo.id} onClick={() => choosePhoto(photo.id)}><img src={photo.src} alt="" /><span>{photo.label}</span></button>)}</div>}
        {sheet?.type === 'create' && <><div className="topic-input">{selectedTag ? <span className="selected-tag">{selectedTag}<IconButton label="删除已选主题" onClick={() => { setSelectedTag(''); setDraft(''); }}><Cross2Icon /></IconButton></span> : <KeyboardInput aria-label="输入你想学习的主题" placeholder="输入你想学习的主题" maxLength={40} value={draft} onChange={e => setDraft(e.target.value)} />}</div>{suggestions.length > 0 && <><div className="suggestion-heading"><span>试试这些</span><IconButton label="换一批推荐" onClick={randomSuggestions}><ReloadIcon /></IconButton></div><div className="suggestions">{suggestions.map(name => <button key={name} aria-pressed={selectedTag === name} onClick={() => { keyboard.hide(); setSelectedTag(name); setDraft(''); }}>{name}</button>)}</div></>}<button className="primary" disabled={!(selectedTag || draft.trim())} onClick={submitTopic}>创建主题<PlusIcon /></button></>}
        {sheet?.type === 'settings' && <div className="toggle-row"><span>填空完成后自动朗读句子</span><button className="switch" role="switch" aria-label="填空完成后自动朗读句子" aria-checked={autoSpeak} onClick={() => { setAutoSpeak(!autoSpeak); try { localStorage.setItem('sanju-studio-current-auto-speak', String(!autoSpeak)); } catch { /* Storage may be disabled. */ } }}><span /></button></div>}
        {sheet?.type === 'nickname' && <><KeyboardInput aria-label="昵称" className="field" value={draft} maxLength={20} onChange={e => setDraft(e.target.value)} /><button className="primary" disabled={!draft.trim()} onClick={() => { setNickname(draft.trim()); close(); }}>保存</button></>}
        {sheet?.type === 'reminder' && <><KeyboardInput type="time" aria-label="提醒时间" className="field" value={draft} onChange={e => setDraft(e.target.value)} /><button className="primary" onClick={() => { setReminderTime(draft || '20:00'); close(); setToast('已保存演示设置，不会发送实际通知。'); }}>保存</button></>}
        {sheet?.type === 'purchase' && <><p className="purchase-balance">剩余可用次数 <strong>{credits}</strong></p><div className="offers">{[200, 365].map(size => <button key={size} aria-pressed={size === purchaseSize} onClick={() => setPurchaseSize(size)}><strong>{size}<small>次生成</small></strong><span>价格由 App Store 提供</span>{size === purchaseSize && <CheckIcon />}</button>)}</div><button className="primary" onClick={() => { setCredits(c => c + purchaseSize); setPurchased(true); close(); setToast(`演示购买完成，增加 ${purchaseSize} 次。未发生真实扣款。`); }}>立即购买<ArrowRightIcon /></button></>}
        {sheet?.type === 'widget' && <><div className="widget-example"><img src="/photos/cat.png" alt="随机回忆小组件预览" /><p>A little kitten is walking through the grass.</p></div><ol className="widget-steps"><li>长按桌面空白处，点击“编辑”或“+”。</li><li>在小组件列表里搜索“三句”。</li><li>选择“随机回忆”，点击“添加小组件”。</li><li>放到喜欢的位置后，点击“完成”。</li></ol></>}
        {sheet?.type === 'login' && <><label className="field-label">邮箱<KeyboardInput className="field" type="email" autoComplete="off" value={authEmail} onChange={e => setAuthEmail(e.target.value)} /></label>{authMode === 'signup' && <label className="field-label">昵称<KeyboardInput className="field" placeholder="请输入昵称，最多 20 个字符" maxLength={20} value={draft} onChange={e => setDraft(e.target.value)} /></label>}{authMode !== 'login' && <label className="field-label">验证码<div className="inline-field"><KeyboardInput className="field" placeholder="演示验证码 123456" /><button onClick={() => setToast('演示验证码：123456（未发送邮件）')}>发送验证码</button></div></label>}<label className="field-label">{authMode === 'reset' ? '新密码' : '密码'}<div className="password-field"><KeyboardInput className="field" autoComplete="off" type={showPassword ? 'text' : 'password'} value={authPassword} onChange={e => setAuthPassword(e.target.value)} /><button onClick={() => setShowPassword(!showPassword)}>{showPassword ? '隐藏' : '显示'}</button></div></label><button className="primary" disabled={!online || !authEmail.includes('@') || authPassword.length < 6} onClick={() => { if (authMode === 'reset') { setAuthMode('login'); setToast('密码修改成功，请重新登录'); } else { setSignedIn(true); if (authMode === 'signup' && draft.trim()) setNickname(draft.trim()); close(); setToast('已进入演示账号，不涉及真实登录。'); } }}>{authMode === 'login' ? '登录' : authMode === 'signup' ? '注册并登录' : '确认重置'}</button>{authMode === 'login' && <button className="text-button wide" onClick={() => setAuthMode('reset')}>忘记密码？</button>}<button className="text-button wide" onClick={() => { setDraft(''); setAuthMode(authMode === 'login' ? 'signup' : 'login'); }}>{authMode === 'login' ? '还没有账号？ 去注册' : '返回登录'}</button><div className="legal">{terms}</div></>}
        {sheet?.type === 'logout' && <><p className="sheet-explanation">本地的回忆将被清除，已同步的数据会在下次登录后恢复。</p><button className="danger-button" onClick={() => { setSignedIn(false); close(); setToast('已切换至未登录演示；展示数据仍为预置样本。'); }}>退出登录</button><button className="secondary" onClick={close}>取消</button></>}
        {sheet?.type === 'deleteAccount' && <><p className="sheet-explanation">此操作不可撤销。请输入“我已知晓后果，确定删除账号”以确认。</p><KeyboardInput aria-label="删除账号确认文字" className="field" value={draft} onChange={e => setDraft(e.target.value)} /><button className="danger-button" disabled={draft !== '我已知晓后果，确定删除账号'} onClick={() => { setSignedIn(false); close(); setToast('删除确认流程演示结束，未操作真实账号。'); }}>删除账号</button></>}
        {sheet?.type === 'deleteTopic' && <><p className="sheet-explanation">删除后，该主题的匹配结果和学习记录将被清除，原始回忆和句子不会受到影响。</p><button className="danger-button" onClick={() => { setTopics(current => current.filter(t => t.id !== sheet.id)); close(); if (route.kind === 'topic' && route.id === sheet.id) go({ kind: 'root' }); }}>删除</button><button className="secondary" onClick={close}>取消</button></>}
        {sheet?.type === 'deleteMemory' && <><p className="sheet-explanation">删除后，这张图片和对应的句子都会被移除。</p><button className="danger-button" onClick={() => deleteMemory(sheet.id!)}>删除</button><button className="secondary" onClick={close}>取消</button></>}
        {sheet?.type === 'unfavorite' && <><button className="danger-button" onClick={() => { toggleFavorite(sheet.id!); close(); }}>取消收藏</button><button className="secondary" onClick={close}>取消</button></>}
        {sheet?.type === 'memoryMenu' && <><button className="secondary" onClick={() => open({ type: 'export', id: sheet.id })}>保存到本地</button><button className="danger-button" onClick={() => open({ type: 'deleteMemory', id: sheet.id })}><TrashIcon />删除</button></>}
        {sheet?.type === 'export' && <><div className="export-preview"><img src={getPhoto(sheet.id!).src} alt="保存内容预览" /><p>{sentences.find(s => s.memory === sheet.id && s.group === group)?.en}</p></div><p className="caption">这是导出样式预览。网页版不会写入系统相册。</p><button className="secondary" onClick={close}>完成</button></>}
      </div>
    </BottomSheet>
  </>;
}
