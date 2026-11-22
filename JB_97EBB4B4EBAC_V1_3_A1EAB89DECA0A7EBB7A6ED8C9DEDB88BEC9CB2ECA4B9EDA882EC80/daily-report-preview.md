# 일일 업무보고 개발용 미리보기

저장소 루트에서 아래 명령으로 로컬 서버를 시작하고 브라우저에서
<http://127.0.0.1:8765/daily-report-preview.html>을 연다. 브라우저 모듈을
불러오기 위해 HTTP를 사용한다.

```sh
python -m http.server 8765 --bind 127.0.0.1 --directory "$(printf '%s\n' JB_*/daily-report-preview.html | xargs dirname)"
node --test JB_*/daily-task-time.test.mjs
```

## 화면과 집계 모듈

미리보기는 `daily-report-preview-fixture.mjs`의 합성 스냅샷과 별도 합성
배정 원장을 `adaptDailyTaskSource()`에 전달한다. 어댑터는 입력을 검증하고
`summarizeDailyTaskTime()`으로 계산한다. 보고 기간 담당이 확인된 업무만
확정 합계에 포함한다. 현재 담당 관계만 있는 업무는 별도 영역에서 상태 기준
시간과 이력을 열어 볼 수 있다. 정상 0건과 데이터 오류는 다른 메시지를 표시한다.
요약과 확인사항은 검증용 규칙으로 작성한다.

저장소 루트에서 자동 검증:

```sh
node --test JB_*/daily-task-adapter.test.mjs JB_*/daily-task-time.test.mjs
node --test JB_*/daily-report-preview.test.mjs
```

브라우저 테스트는 Node에서 해석 가능한 Playwright와 Chromium이 필요하다.
기본 실행 파일은 /usr/bin/chromium이며 다른 위치는
PLAYWRIGHT_CHROMIUM_EXECUTABLE로 지정한다. 테스트는 외부 네트워크를
차단하고 로컬 파일만 로드한다.

## 실데이터 연결 전 확인

- 서버에서 대표님 또는 승인된 보고 조회 역할을 검증한다. 기존 Supabase
  RLS로 권한별 조회 범위를 확인하고, 권한 부족을 빈 결과나 완전 조회로
  처리하지 않는다. 브라우저에 서비스 역할 키를 전달하지 않는다.
- `jb_tasks`의 업무 ID, `assignee_id`, `created_at`, 상태를 읽고
  `jb_employees.id`로 담당자 식별자를 대조한다. 초기 연동에서는 각 업무의
  생성부터 보고 마감까지 `jb_task_history`를 읽는다. 시각, 원본 이벤트 ID,
  이전·새 상태, 실행자를 함께 가져온다. 마감 상태와 완료 여부는 전환 이력으로
  판정한다. 현재 상태와 현재 완료 시각을 과거 마감의 값으로 사용하지 않는다.
- 한 읽기 전용 스냅샷에서 후보 업무와 이력을 조회하는 경로를 검증한다.
  이력은 `(changed_at, id)` 커서와 같은 정렬로 페이지를 순회하고 마지막
  페이지와 기대 건수를 대조한다. 동일 시각의 ID 순서는 페이지 경계에만
  사용한다. 업무 상태 전환의 인과 순서를 추정하는 근거로 사용하지 않는다.
  실패나 권한 누락으로 중간 범위가 비면 `coverageByTask`에 해당 범위를
  보장하지 않는다. 이력 조회는 승인된 역할로 별도 검증해야 한다.
- 서울 자정 직전 상태는 자정 이전 마지막 유효 전환으로 복원한다. 같은 시각에
  서로 다른 전환이 있으면 모순 여부를 확인한다. 전체 이력 대신 이전 상태
  조회를 도입하려면 복원 근거를 집계 모듈에 전달하는 계약을 먼저 추가한다.
- `jb_task_assignment_ack_v13`은 일부 업무의 확인 요청을 업무당 한 건으로
  덮어쓰거나 삭제한다. 이를 담당자 재배정 원장으로 사용할 수 없다.
  신뢰할 수 있는 독립 배정 원장으로 보고 구간의 담당 관계를 검증할 수
  있을 때에만 어댑터에 `assignmentLedger`를 제공한다. `changed_by`는 상태를 변경한 실행자다.
