// Synthetic report inputs only. No application's credentials or production records.
const id = n => '00000000-0000-0000-0000-' + String(n).padStart(12, '0');
const time = (value, day = '22') =>
  new Date(`2026-11-${day}T${value}:00+09:00`).toISOString().replace(/Z$/, '000Z');

export const date = '2026-11-22';
export const cutoffTime = '18:00';
export const staff = [
  { id: id(1), name: '합성 직원 가' },
  { id: id(2), name: '합성 직원 나' },
];
export const reviewerId = id(3);

const [a, b] = staff.map(person => person.id);
const tasks = [
  { id: id(11), assignee_id: b, title: '화분 진열 위치 점검', created_at: time('08:30'), status: 'completed' },
  { id: id(12), assignee_id: a, title: '온실 점검 기록 정리', created_at: time('14:00', '21'), status: 'completed' },
  { id: id(13), assignee_id: a, title: '포장 자재 예약 확인', created_at: time('14:00'), status: 'planned' },
  { id: id(14), assignee_id: b, title: '관수 상태 관찰', created_at: time('21:30', '21'), status: 'completed' },
  { id: id(15), assignee_id: b, title: '입고 준비 목록 점검', created_at: time('12:00', '21'), status: 'completed' },
  { id: id(16), assignee_id: b, title: '작업대 재배치 검토', created_at: time('15:00'), status: 'planned' },
];
export const titles = new Map(tasks.map(task => [task.id, task.title]));

const cutoff = time(cutoffTime);
const afterCutoff = time('19:00');
const history = [
  [14, time('23:30', '21'), 'planned', 'in_progress'],
  [11, time('09:00'), 'planned', 'in_progress'],
  [11, time('10:00'), 'in_progress', 'hold'],
  // Missing earlier transition deliberately exercises the engine's unknown time.
  [15, time('10:00'), 'in_progress', 'hold'],
  [11, time('11:00'), 'hold', 'in_progress'],
  [15, time('11:00'), 'hold', 'completed'],
  [11, time('12:00'), 'in_progress', 'completed', reviewerId],
  [12, time('13:00'), 'planned', 'completed'],
  [14, afterCutoff, 'in_progress', 'completed'],
].map(([task, changed_at, previous_status, new_status, changed_by = null], index) =>
  ({ id: id(100 + index), task_id: id(task), changed_at, previous_status, new_status, changed_by }))
  .filter(event => event.changed_at <= cutoff);

const snapshotId = 'synthetic-preview';
function dataset(rows) {
  return { count: rows.length, pages: [{ rows, status: 'ok', snapshotId, after: null, done: true }] };
}
export const source = {
  status: 'ok', authorization: 'verified', snapshotId, cutoff, asOf: afterCutoff,
  contract: 'jb-task-source-v1', scope: 'all_tasks_created_through_cutoff_with_history',
  taskStatuses: ['planned', 'in_progress', 'hold', 'completed'],
  schema: {
    jb_tasks: { id: 'uuid!', assignee_id: 'uuid?', created_at: 'timestamptz!', status: 'text!' },
    jb_task_history: {
      id: 'uuid!', task_id: 'uuid!', changed_by: 'uuid?', previous_status: 'text?',
      new_status: 'text!', changed_at: 'timestamptz!',
    },
    jb_employees: { id: 'uuid!' },
  },
  tasks: dataset(tasks),
  history: dataset(history),
};

// Explicit synthetic assignment periods model an after-cutoff reassignment and missing evidence.
export const assignmentLedger = { snapshotId, periods: [
  { taskId: id(11), employeeId: a, from: tasks[0].created_at, to: afterCutoff },
  { taskId: id(11), employeeId: b, from: afterCutoff, to: null },
  { taskId: id(12), employeeId: a, from: tasks[1].created_at, to: null },
  { taskId: id(13), employeeId: a, from: tasks[2].created_at, to: null },
  { taskId: id(15), employeeId: b, from: tasks[4].created_at, to: null },
] };
