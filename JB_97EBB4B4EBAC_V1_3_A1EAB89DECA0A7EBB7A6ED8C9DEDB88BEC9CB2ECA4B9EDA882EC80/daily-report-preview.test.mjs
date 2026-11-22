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
