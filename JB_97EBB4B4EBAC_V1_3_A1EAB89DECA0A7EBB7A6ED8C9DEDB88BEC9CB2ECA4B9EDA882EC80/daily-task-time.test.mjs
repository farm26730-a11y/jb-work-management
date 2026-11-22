import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import { summarizeDailyTaskTime } from './daily-task-time.mjs';

const date = '2026-11-22';
const cutoff = date + 'T18:00:00+09:00';
const minute = 60_000;
const at = (time, day = date) => day + 'T' + time + ':00+09:00';
const yesterday = time => at(time, '2026-11-21');
const task = (overrides = {}) => ({
  id: 'task-a', assignee_id: 'employee-a', assignmentVerified: true,
  created_at: at('08:00'), status: 'planned', ...overrides,
});
const event = (changed_at, previous_status, new_status, extra = {}) => ({
  task_id: 'task-a', changed_at, previous_status, new_status, ...extra,
});
const run = (history, tasks = [task()], options = {}) => summarizeDailyTaskTime({
  date, cutoffTime: '18:00', employeeId: 'employee-a', history, tasks,
  coverageByTask: new Map(tasks.map(row => [row.id, { through: cutoff }])),
  ...options,
});
const start = (when, extra) => event(when, 'planned', 'in_progress', extra);

test('01 등록 후 진행', () => {
  const [row] = run([start(at('09:00'))]).tasks;
  assert.equal(row.registeredToday, true);
  assert.equal(row.workedToday, true);
  assert.equal(row.completedToday, false);
  assert.equal(row.runningMs, 540 * minute);
  assert.equal(row.holdMs, 0);
});

const repeated = [
  start(at('09:00')),
  event(at('10:00'), 'in_progress', 'hold'),
  event(at('11:00'), 'hold', 'in_progress'),
  event(at('12:00'), 'in_progress', 'completed', { changed_by: 'actor-b' }),
];

test('02 반복 진행과 보류 및 실행자 구분', () => {
  const [row] = run(repeated).tasks;
  assert.equal(row.runningMs, 120 * minute);
  assert.equal(row.holdMs, 60 * minute);
  assert.equal(row.completedToday, true);
  assert.equal(row.completions[0].changedBy, 'actor-b');
  assert.equal(row.assigneeId, 'employee-a');
});

test('03 자정을 넘기는 진행', () => {
  const [row] = run([
    start(yesterday('23:30')), event(at('01:00'), 'in_progress', 'completed'),
  ], [task({ created_at: yesterday('22:00') })]).tasks;
  assert.equal(row.runningMs, 60 * minute);
  assert.equal(row.registeredToday, false);
});

test('04 자정을 넘기는 보류', () => {
  const [row] = run([
    start(yesterday('21:00')), event(yesterday('23:00'), 'in_progress', 'hold'),
    event(at('02:00'), 'hold', 'completed'),
  ], [task({ created_at: yesterday('20:00') })]).tasks;
  assert.equal(row.runningMs, 0);
  assert.equal(row.holdMs, 120 * minute);
});

test('05 어제 등록하고 오늘 완료', () => {
  const [row] = run([start(at('09:00')), event(at('10:00'), 'in_progress', 'completed')],
    [task({ created_at: yesterday('10:00') })]).tasks;
  assert.deepEqual([row.registeredToday, row.workedToday, row.completedToday], [false, true, true]);
});

test('06 진행 없이 완료', () => {
  const [row] = run([event(at('12:00'), 'planned', 'completed')]).tasks;
  assert.deepEqual([row.runningMs, row.workedToday, row.completedToday], [0, false, true]);
});

test('07 마감 이후 변경 및 이후 스냅샷 제외', () => {
  const [row] = run([start(at('17:00')), event(at('19:00'), 'in_progress', 'completed')],
    [task({ status: 'completed', status_as_of: at('19:00') })]).tasks;
  assert.equal(row.runningMs, 60 * minute);
  assert.equal(row.stateAtCutoff, 'in_progress');
  assert.equal(row.completedToday, false);
  assert.deepEqual(row.issues, []);
});

test('08 생성 이전 이력과 유효하지 않은 날짜', () => {
  const [row] = run([start(at('07:00')), start(at('10:00'))]).tasks;
  assert.equal(row.runningMs, 480 * minute);
  assert.deepEqual(row.issues, ['event_before_creation']);
  const [invalid] = run([start('2026-11-31T10:00:00Z')]).tasks;
  assert.equal(invalid.runningMs, null);
  assert.ok(invalid.issues.includes('invalid_event_time'));
});

test('09 중복·역순 복구 및 모순 구간 분리', () => {
  const [row] = run([repeated[2], repeated[0], repeated[1], repeated[1], repeated[3]]).tasks;
  assert.equal(row.runningMs, 120 * minute);
  assert.equal(row.holdMs, 60 * minute);
  assert.deepEqual(row.issues, ['out_of_order', 'duplicate_event']);
  const [gap] = run([start(at('09:00')), event(at('10:00'), 'hold', 'in_progress'),
    event(at('11:00'), 'in_progress', 'completed')]).tasks;
  assert.equal(gap.runningMs, null);
  assert.equal(gap.knownStateMs.in_progress, 60 * minute);
  assert.equal(gap.unknownMs, 60 * minute);
  assert.ok(gap.issues.includes('state_discontinuity'));
});

test('10 선행 이력이 잘린 경우 미확인, 이후 구간 유지', () => {
  const tasks = [task({ created_at: yesterday('20:00') })];
  const [row] = run([
    event(at('10:00'), 'in_progress', 'hold'), event(at('11:00'), 'hold', 'completed'),
  ], tasks, { coverageByTask: new Map([['task-a', { from: at('08:00'), through: cutoff }]]) }).tasks;
  assert.equal(row.runningMs, null);
  assert.equal(row.holdMs, null);
  assert.equal(row.knownStateMs.hold, 60 * minute);
  assert.equal(row.unknownMs, 600 * minute);
  assert.equal(row.completedToday, true);
  assert.ok(row.issues.includes('partial_history'));
});

test('11 완료 이후 비정상 전환은 진행으로 계산하지 않음', () => {
  const [row] = run([...repeated, event(at('13:00'), 'completed', 'in_progress'),
    event(at('14:00'), 'in_progress', 'hold')]).tasks;
  assert.equal(row.runningMs, null);
  assert.equal(row.knownStateMs.in_progress, 120 * minute);
  assert.equal(row.completedToday, true);
  assert.equal(row.stateAtCutoff, null);
  assert.ok(row.issues.includes('transition_after_completion'));
});

test('12 서울 날짜와 UTC 시각, 마감 정각 완료', () => {
  const result = run([
    start('2026-11-21T14:30:00Z'),
    event('2026-11-22T09:00:00Z', 'in_progress', 'completed'),
  ], [task({ created_at: '2026-11-21 14:00:00+00' })]);
  assert.equal(result.start, '2026-11-21T15:00:00.000000Z');
  assert.equal(result.cutoff, '2026-11-22T09:00:00.000000Z');
  assert.equal(result.tasks[0].runningMs, 1080 * minute);
  assert.equal(result.tasks[0].completedToday, true);
  assert.throws(() => run([], [], { date: '2026-02-30' }), RangeError);
  assert.throws(() => run([], [], { cutoffTime: '24:00' }), RangeError);
});

test('13 합성 직원의 여러 업무 교대 및 미확인 담당 제외', () => {
  const tasks = [task(), task({ id: 'task-b' }),
    task({ id: 'task-c', assignmentVerified: false }),
    task({ id: 'task-d', assignee_id: 'another-employee' })];
  const result = run([
    start(at('09:00')), event(at('10:00'), 'in_progress', 'hold'),
    event(at('10:00'), 'planned', 'in_progress', { task_id: 'task-b' }),
    event(at('11:00'), 'in_progress', 'completed', { task_id: 'task-b' }),
    event(at('11:00'), 'hold', 'in_progress'), event(at('12:00'), 'in_progress', 'completed'),
  ], tasks);
  assert.deepEqual(result.tasks.map(row => [row.taskId, row.runningMs / minute, row.holdMs / minute]),
    [['task-a', 120, 60], ['task-b', 60, 0]]);
  assert.deepEqual(result.unverifiedAssignment.map(row => row.taskId), ['task-c']);
});

const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
test('14 기존 taskClock 전체 기간과 일치', () => {
  const original = html.match(/function taskClock\(t, now=Date\.now\(\)\)\{[\s\S]*?\n\}/)[0];
  const input = task({ status: 'completed' });
  const legacy = vm.runInNewContext(original + '\ntaskClock(input, cutoff);', {
    input, cutoff: Date.parse(cutoff), records: { taskHistory: repeated },
  });
  const [row] = run(repeated, [input]).tasks;
  assert.equal(legacy.valid, true);
  assert.equal(row.runningMs, legacy.running);
  assert.equal(row.holdMs, legacy.holding);
  assert.equal(row.knownStateMs.planned, legacy.planned);
});

test('15 기존 앱 인라인 스크립트 문법', () => {
  const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)]
    .map(match => match[1]).filter(script => script.trim());
  assert.equal(scripts.length, 4);
  for (const script of scripts) assert.doesNotThrow(() => new vm.Script(script));
});

test('16 마감 스냅샷 불일치 및 조회 끝 누락', () => {
  const [mismatch] = run([start(at('09:00'))], [task({ status: 'hold', status_as_of: cutoff })]).tasks;
  assert.equal(mismatch.runningMs, null);
  assert.ok(mismatch.issues.includes('snapshot_mismatch'));
  const [partial] = run([start(at('09:00'))], [task()], {
    coverageByTask: new Map([['task-a', { through: at('10:00') }]]),
  }).tasks;
  assert.equal(partial.runningMs, null);
  assert.equal(partial.knownStateMs.in_progress, 60 * minute);
  assert.equal(partial.stateAtCutoff, null);
  assert.equal(partial.completedToday, null);
});

test('17 마이크로초 순서와 동시각 충돌', () => {
  const begin = date + 'T09:00:00.000100+09:00';
  const end = date + 'T09:00:00.000400+09:00';
  const [clean] = run([start(begin), event(end, 'in_progress', 'completed')]).tasks;
  assert.equal(clean.runningMs, 0.3);
  const [conflict] = run([start(begin), event(begin, 'in_progress', 'hold')]).tasks;
  assert.equal(conflict.runningMs, null);
  assert.ok(conflict.issues.includes('conflicting_event_time'));
});

test('18 조회 범위가 없으면 미확인, 잘못된 생성 날짜도 미확인', () => {
  const [noCoverage] = run([], [task()], { coverageByTask: new Map() }).tasks;
  assert.equal(noCoverage.runningMs, null);
  assert.equal(noCoverage.workedToday, null);
  const [bad] = run([], [task({ created_at: '2026-02-30T12:00:00Z' })]).tasks;
  assert.equal(bad.registeredToday, null);
  assert.equal(bad.runningMs, null);
});

test('19 조회 범위가 전일부터 시작해도 선행 상태가 없으면 미확인', () => {
  const [row] = run([], [task({ created_at: yesterday('18:00') })], {
    coverageByTask: new Map([['task-a', { from: yesterday('22:00'), through: cutoff }]]),
  }).tasks;
  assert.equal(row.runningMs, null);
  assert.equal(row.unknownMs, 1080 * minute);
  assert.ok(row.issues.includes('missing_start_state'));
});

test('20 당일 전환 없이 이어진 진행과 마감 이후 동일 ID 분리', () => {
  const [row] = run([
    start(yesterday('22:00'), { id: 'same' }),
    event(at('19:00'), 'in_progress', 'completed', { id: 'same' }),
  ], [task({ created_at: yesterday('21:00') })]).tasks;
  assert.equal(row.runningMs, 1080 * minute);
  assert.equal(row.stateAtCutoff, 'in_progress');
  assert.deepEqual(row.transitions, []);
  assert.deepEqual(row.issues, []);
});

test('21 자정 및 마감 정각 전환, 중복은 화면용 이력에서도 한 번만 반환', () => {
  const beginning = start('2026-11-21T15:00:00Z');
  const end = event(cutoff, 'in_progress', 'completed', { changed_by: 'actor-b' });
  const [row] = run([beginning, beginning, end], [task({ created_at: yesterday('21:00') })]).tasks;
  assert.equal(row.runningMs, 1080 * minute);
  assert.deepEqual(row.transitions.map(({ from, to, changedBy }) => [from, to, changedBy]),
    [['planned', 'in_progress', null], ['in_progress', 'completed', 'actor-b']]);
});

test('22 중간 페이지 누락 시 연속 조회 보장 범위 밖 전환을 사용하지 않음', () => {
  const [row] = run([start(at('09:00')), event(at('16:00'), 'hold', 'completed')], [task()], {
    coverageByTask: new Map([['task-a', { through: at('10:00') }]]),
  }).tasks;
  assert.equal(row.runningMs, null);
  assert.equal(row.knownStateMs.in_progress, 60 * minute);
  assert.equal(row.unknownMs, 480 * minute);
  assert.equal(row.completedToday, null);
  assert.equal(row.transitions.length, 1);
});

test('23 미검증 페이지의 중복 ID가 검증된 구간을 지우지 않음', () => {
  const [row] = run([
    start(at('09:00'), { id: 'a' }),
    event(at('16:00'), 'hold', 'completed', { id: 'a' }),
  ], [task()], { coverageByTask: new Map([['task-a', { through: at('10:00') }]]) }).tasks;
  assert.equal(row.knownStateMs.in_progress, 60 * minute);
  assert.equal(row.runningMs, null);
  assert.equal(row.transitions.length, 1);
  assert.deepEqual(row.issues, ['partial_history']);
});
