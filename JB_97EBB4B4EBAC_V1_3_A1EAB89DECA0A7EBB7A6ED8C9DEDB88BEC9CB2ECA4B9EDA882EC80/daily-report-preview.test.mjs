import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import test from 'node:test';
import { adaptDailyTaskSource } from './daily-task-adapter.mjs';
import { date, cutoffTime, staff, source, assignmentLedger } from './daily-report-preview-fixture.mjs';

const { chromium } = createRequire(import.meta.url)('playwright');
const origin = 'http://127.0.0.1';
const contentTypes = new Map([
  ['daily-report-preview.html', 'text/html; charset=utf-8'],
  ...['daily-report-preview-fixture.mjs', 'daily-task-adapter.mjs', 'daily-task-time.mjs']
    .map(name => [name, 'text/javascript; charset=utf-8']),
]);
const employee = (page, person) => page.locator('[data-employee="' + person.id + '"]');
const work = (group, row) => group.locator('[data-task="' + row.taskId + '"]');

async function openPreview(browser, fixtureOverride = '') {
  const page = await browser.newPage({
    viewport: { width: 393, height: 851 }, isMobile: true, hasTouch: true, offline: true,
  });
  await page.route('**/*', async route => {
    const url = new URL(route.request().url());
    const name = url.pathname.slice(1);
    if (url.origin !== origin || !contentTypes.has(name)) return route.abort();
    let body = await readFile(new URL('./' + name, import.meta.url), 'utf8');
    if (name === 'daily-report-preview-fixture.mjs') body += '\n' + fixtureOverride;
    await route.fulfill({ body, contentType: contentTypes.get(name) });
  });
  await page.goto(origin + '/daily-report-preview.html');
  return page;
}

test('393px preview presents adapter data, separate attribution and collapsible details', async () => {
  const browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || '/usr/bin/chromium',
  });
  try {
    const page = await openPreview(browser);
    await page.locator('.employee').first().waitFor();
    assert.deepEqual(await page.locator('h2').allTextContents(),
      ['AI 종합요약', '직원별 업무', 'AI 확인사항', '대표님 결정사항', '업무 현황']);
    assert.match(await page.locator('.summary').innerText(), /검증용 규칙 기반 요약/);
    assert.equal(await page.locator('details[open]').count(), 0);

    const [first, second] = staff;
    const reports = staff.map(({ id: employeeId }) =>
      adaptDailyTaskSource({ date, cutoffTime, employeeId, source, assignmentLedger }).report);
    const firstEmployee = employee(page, first);
    await firstEmployee.locator(':scope > summary').tap();
    assert.equal(await firstEmployee.evaluate(element => element.open), true);
    const confirmed = firstEmployee.locator('.confirmed');
    for (const row of reports[0].tasks) assert.equal(await work(confirmed, row).count(), 1);
    const sum = reports[0].tasks.reduce((total, row) => total + row.runningMs / 60_000, 0);
    assert.match(await confirmed.innerText(), new RegExp('확정 업무 진행 합계\\s*' + sum + '분'));

    const reassigned = work(confirmed, reports[0].tasks.find(row => row.currentAssigneeId === second.id));
    await reassigned.locator('summary').tap();
    assert.match(await reassigned.innerText(), /보고 기간 담당: 합성 직원 가 · 현재 담당: 합성 직원 나/);
    assert.match(await reassigned.innerText(), /10:00 · 진행 중 → 보류/);
    await reassigned.locator('summary').tap();
    assert.equal(await reassigned.evaluate(element => element.open), false);
    const zero = work(confirmed, reports[0].tasks.find(row => row.completedToday && row.runningMs === 0));
    await zero.locator('summary').tap();
    assert.match(await zero.innerText(), /진행 0분 · 보류 0분/);
    await firstEmployee.locator(':scope > summary').tap();
    assert.equal(await firstEmployee.evaluate(element => element.open), false);

    const secondEmployee = employee(page, second);
    await secondEmployee.locator(':scope > summary').tap();
    const historicalUnknown = secondEmployee.locator('.assignment-unverified');
    assert.match(await historicalUnknown.innerText(), /현재 담당 업무 · 보고 당시 담당자 미확인/);
    assert.equal(await historicalUnknown.locator('.work').count(), reports[1].unverifiedAssignment.length);
    const carry = reports[1].unverifiedAssignment.find(row => row.runningMs > 0);
    const carryDetail = work(historicalUnknown, carry);
    await carryDetail.locator('summary').tap();
    assert.match(await carryDetail.innerText(), /진행 1,080분/);
    assert.equal(carry.runningMs, 1080 * 60_000);
    assert.match(await carryDetail.innerText(), /00:00–18:00 · 진행 중/);
    const secondConfirmed = secondEmployee.locator('.confirmed');
    assert.match(await secondConfirmed.innerText(), /확정 업무 진행 합계\s*미확인/);
    assert.doesNotMatch(await secondConfirmed.innerText(), /1,080/);
    assert.equal(await work(secondEmployee, reports[0].tasks[0]).count(), 0);
    const unknown = work(secondConfirmed, reports[1].tasks.find(row => row.runningMs === null));
    await unknown.locator('summary').tap();
    assert.match(await unknown.innerText(), /진행 미확인/);

    await page.locator('#counts').scrollIntoViewIfNeeded();
    assert.deepEqual(await page.evaluate(() => [innerWidth, document.documentElement.scrollWidth, scrollY > 0]),
      [393, 393, true]);
  } finally {
    await browser.close();
  }
});

test('preview distinguishes confirmed zero, read error, and incompatible schema', async () => {
  const browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || '/usr/bin/chromium',
  });
  try {
    for (const [override, expected] of [
      ["source.tasks = { count: 0, pages: [{ status: 'ok', snapshotId, after: null, done: true, rows: [] }] }; source.history = source.tasks; assignmentLedger.periods = [];", /업무가 0건/],
      ["source.status = 'error';", /업무 원본 조회에 실패/],
      ["delete source.schema.jb_tasks.assignee_id;", /데이터 계약이 바뀌었습니다/],
    ]) {
      const page = await openPreview(browser, override);
      await page.getByText(expected).waitFor();
      assert.equal(await page.locator('.employee').count(), 0);
      await page.close();
    }
  } finally {
    await browser.close();
  }
});

test('393px preview renders data-derived titles and names as literal text', async () => {
  const browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || '/usr/bin/chromium',
  });
  try {
    const title = '화분 <특수> & "큰따옴표" \'작은따옴표\'';
    const scriptText = '<script data-preview-marker>window.previewMarker = true;</script>';
    const historicalName = '담당 <b data-preview-marker>가</b> & 검토';
    const currentName = '현재 <em data-preview-marker>나</em>';
    const taskIds = source.tasks.pages[0].rows.map(row => row.id);
    const page = await openPreview(browser, [
      `titles.set(${JSON.stringify(taskIds[0])}, ${JSON.stringify(title)});`,
      `titles.set(${JSON.stringify(taskIds[3])}, ${JSON.stringify(scriptText)});`,
      `staff[0].name = ${JSON.stringify(historicalName)};`,
      `staff[1].name = ${JSON.stringify(currentName)};`,
    ].join('\n'));
    const [first, second] = staff.map(person => employee(page, person));
    await first.locator(':scope > summary').waitFor();
    assert.match(await first.locator(':scope > summary').innerText(), /담당 <b data-preview-marker>가<\/b> & 검토/);
    await first.locator(':scope > summary').tap();
    const verified = first.locator('.confirmed .work').first();
    assert.ok((await verified.locator('summary').innerText()).includes(title));
    await verified.locator('summary').tap();
    assert.ok((await verified.innerText()).includes('보고 기간 담당: ' + historicalName + ' · 현재 담당: ' + currentName));

    await second.locator(':scope > summary').tap();
    const unverified = second.locator('.assignment-unverified .work').first();
    assert.ok((await unverified.locator('summary').innerText()).includes(scriptText));
    assert.ok((await page.locator('#review').innerText()).includes(scriptText));
    assert.equal(await page.locator('main [data-preview-marker]').count(), 0);
    assert.equal(await page.evaluate(() => window.previewMarker), undefined);
  } finally {
    await browser.close();
  }
});

test('393px integrated preview refreshes date and cutoff and reports unassigned and prior work', async () => {
  const browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || '/usr/bin/chromium',
  });
  try {
    const page = await openPreview(browser);
    await page.locator('.employee').first().waitFor();
    assert.match(await page.locator('#counts').innerText(), /전체 업무\s*7건/);
    assert.match(await page.locator('#counts').innerText(), /보고일 전에 종료\s*1건/);
    await page.locator('#unassigned summary').first().tap();
    assert.match(await page.locator('#unassigned').innerText(), /분갈이 자재 점검/);
    assert.equal(await page.getByText('전일에 종료한 업무').count(), 0);

    await page.getByLabel('마감시각').fill('10:00');
    await page.getByRole('button', { name: '보고 조회' }).tap();
    assert.match(await page.locator('#report-window').innerText(), /2026-11-22 · 10:00/);
    await employee(page, staff[0]).locator(':scope > summary').tap();
    assert.match(await employee(page, staff[0]).locator('.confirmed').innerText(), /확정 업무 진행 합계\s*60분/);

    await page.getByLabel('보고일').fill('2026-11-21');
    await page.getByRole('button', { name: '보고 조회' }).tap();
    assert.match(await page.locator('#report-window').innerText(), /2026-11-21 · 10:00/);
    assert.equal(await page.locator('.employee[open]').count(), 0);
    await page.locator('#unassigned summary').first().tap();
    assert.match(await page.locator('#unassigned').innerText(), /전일에 종료한 업무/);

    await page.getByLabel('보고일').fill('2026-11-23');
    await page.getByRole('button', { name: '보고 조회' }).tap();
    assert.match(await page.locator('#overview').innerText(), /조회가 완료되지 않았습니다/);
    assert.equal(await page.locator('.employee').count(), 0);
    assert.equal(await page.locator('#counts').innerText(), '');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 393);
  } finally {
    await browser.close();
  }
});

test('integrated output retains provenance and groups each relevant JB task exactly once', async () => {
  const { loadSyntheticDailyReport } = await import('./daily-report-preview-fixture.mjs');
  const { report } = loadSyntheticDailyReport({ date, cutoffTime });
  const rows = report.employees.flatMap(person => [...person.tasks, ...person.unverifiedAssignment]).concat(report.unassigned);
  assert.equal(report.contract, 'jb-integrated-daily-report-v1');
  assert.equal(new Set(rows.map(row => row.sourceSystem + '/' + row.sourceTaskId)).size, rows.length);
  assert.ok(rows.every(row => row.sourceSystem === 'jb_app'));
  assert.equal(report.counts.total, rows.length);
  assert.equal(report.counts.unassigned, 1);
  assert.equal(report.counts.unresolvedAssignment, 3);
  assert.equal(report.counts.running, 1);
  assert.equal(report.counts.attributedRunning, 0);
  assert.deepEqual(report.sources, [
    { system: 'jb_app', checkedAt: source.asOf, status: 'ready' },
    { system: 'notion', checkedAt: null, status: 'not_connected' },
    { system: 'naver_works', checkedAt: null, status: 'not_connected' },
  ]);
  assert.equal(report.summaryInput.kind, 'rule_based');
  assert.equal(report.summaryInput.timeBasis, '업무 상태 기준 시간');
});
