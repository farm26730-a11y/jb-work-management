# 일일보고 서버 조회 계층

`createDailyReportReader({ verifyAccessToken, withReadOnlySnapshot })`는 서버
내부에서 호출한다. HTTP 경로, 인증 클라이언트, DB 드라이버, 배포 설정은
포함하지 않는다. 포트가 연결되지 않으면 `not_implemented`를 반환한다.
포트는 서버 구성 코드에서만 연결한다.

## 인증 및 권한

- `verifyAccessToken(session)`은 서버에서 기존 Supabase Auth 제공자에
  접근 토큰의 유효성을 확인하고 검증된 `{ userId }`를 반환한다.
  제공자가 토큰을 거부하면 null을 반환하고, 제공자 장애는 예외로 구분한다.
  승인된 환경의 프로젝트에만 연결한다. 운영과 개발의 프로젝트·발급자·대상·
  유효기간 및 세션 취소 검증을 연결 전에 확인한다.
- 트랜잭션의 `findEmployeesByAuthUserId(userId)`로 원본 직원 행을 찾는다.
  일치하는 단일 행의 ID, `auth_user_id`, `active === true`,
  `app_role === 'owner'`를 조회 계층에서 확인한다. 미연결·중복·비활성
  계정과 manager·staff는 대상 직원 및 업무 조회 전에 차단한다.
- 요청의 `employeeId`는 조회 대상을 지정한다. 그 값이나 요청에 붙인
  역할·권한 표시로 호출자를 인증하지 않는다. owner 검증 후 같은
  트랜잭션에서 `findEmployeeById(employeeId)`의 일치를 확인한다.
  권한을 승인한 owner는 다른 확인된 직원의 보고서도 조회할 수 있다.

## 트랜잭션과 어댑터 계약

`withReadOnlySnapshot(callback)`은 실제 읽기 전용 REPEATABLE READ
트랜잭션이나 동일 가시성이 입증된 서버 메커니즘에서 callback을 실행하고,
트랜잭션이 성공적으로 끝난 뒤 결과를 반환해야 한다. callback의 거래 객체만
통해 호출자·대상 직원 및 보고 원본을 조회한다. 상태 이력 페이지를 포함한
조회는 모두 같은 데이터 가시성을 공유한다. 목업 callback과 문자열 식별자만
일치하는 환경에서는 실제 스냅샷 보장을 주장할 수 없다.

거래 객체의 `readReportSource({ employeeId, start, cutoff })`는 서울 기준
보고일·마감에서 계산한 UTC 경계를 사용한다. 단계 7 원본 계약에 따라
마감까지 생성된 업무·이력, 스키마 및 업무 상태 제약, 독립 COUNT, 전체 커서
페이지를 같은 조회 범위에서 수집한다. 현재 담당자만 기준으로 원본을 줄이면
과거에 배정됐다가 변경된 업무가 누락될 수 있다. 권한이나 원천 범위가 부족하면
0건으로 처리하지 않는다. 변경 없는 원본 레코드도 확정 이력 부족과 구별한다.

이 포트는 내부에서 생성한 `{ source, assignmentLedger? }`를 반환한다.
기존 어댑터는 범위·스냅샷 식별자·건수·페이지·호환성을 검증하고 엔진을
호출한다. 마감 이후에 읽은 현재 상태는 과거 마감 상태를 덮어쓰지 않는다.
신뢰할 수 있는 배정 이력이 없다면 담당 미확인으로 남긴다.
`source.authorization`은 서버 계약 표시이며 인증 증명이 아니다.
오류 결과는 보고 데이터 없이 반환하며 제공자의 원문 예외는 노출하지 않는다.

## 연결 전 확인 사항

실제 Supabase Auth 포트, 읽기 전용 DB 계정·연결 방식, 일관 트랜잭션 구현,
배정 원장 출처는 컨트롤타워가 검토한다. 역할별 실제 계정·RLS와 조회
스냅샷의 동시 변경 사례는 승인된 환경에서 검증한다. 현재 앱의 인증·RPC·
RLS·스키마는 그대로 둔다. 공개 응답은 승인된 필드만 선택하며 실제 데이터·
키는 클라이언트, 공개 파일, 테스트 기록에 저장하지 않는다.

검토 작업 트리 루트에서 합성 테스트를 실행한다.

```sh
node --test JB_*/daily-report-server.test.mjs
node --test JB_*/daily-{task-time,task-adapter,report-preview,report-server}.test.mjs
```

## JB-DEV 연결 모듈

서버 내부에서 `daily-report-jb-dev.mjs`의
`createJbDevDailyReportReader()`를 한 번 생성해 재사용한다. 이 모듈을
미리보기나 기존 앱에 포함하지 않는다. 서버 실행 환경에 승인된 `pg` 8.x
드라이버가 필요하며, DB 사용 시에만 불러온다.

환경변수 이름:

- `JB_REPORT_SUPABASE_URL` — JB-DEV의 공식 HTTPS Supabase URL.
- `JB_REPORT_SUPABASE_PUBLISHABLE_KEY` — 같은 프로젝트의 publishable 키.
- `JB_REPORT_DATABASE_URL` — 승인된 읽기 전용 JB-DEV PostgreSQL DSN.
  직접 연결 또는 프로젝트가 일치하는 Supabase pooler DSN을 사용한다.
  TLS 호스트 검증을 적용하는 `sslmode=verify-full`이 필요하다.
  운영 프로젝트, 광역 계정 및 임의 DSN 옵션은 거부한다.
  컨트롤타워 확인에 따라 supabase_read_only_user도 BYPASSRLS 계정으로
  분류해 차단한다. postgres, supabase_admin, service_role도 사용하지 않는다.
  실제 DB 계정 사용에는 컨트롤타워의 별도 승인이 필요하다.

세 값 가운데 하나라도 없으면 `not_implemented`를 반환한다. 공식
Supabase Auth 사용자 조회(`GET /auth/v1/user`, SDK의 `getUser(jwt)`에
해당)로 토큰을 검증한다. JWT의 발급자·만료·주체를 읽는 것은 사전 거부와
검증된 사용자 응답 비교에만 사용한다. 토큰이나 연결정보를 기록하지 않는다.

PostgreSQL 연결부는 한 연결에서 읽기 전용 REPEATABLE READ를 시작하고,
실제 스냅샷 식별자와 트랜잭션 시각을 얻는다. 카탈로그 계약, 승인된 업무
범위의 독립 건수, 전체 키셋 페이지를 같은 트랜잭션에서 읽는다. UTC 시각은
SQL에서 마이크로초 6자리로 포맷해 JavaScript Date 왕복에 따른 정밀도 손실을
피한다. 업무 ID와 이력 (changed_at, id)를 커서로 쓰고, 현재 담당자로 범위를
줄이지 않는다. 준비 및 정상 빈 결과는 COMMIT, 실패는 ROLLBACK이며
연결을 반환한다. 직원이나 보고 데이터를 읽기 전에 현재 역할 및 세션
역할의 광역 역할 멤버십·관리 속성(BYPASSRLS 포함)과 public 생성 권한,
대상 테이블의 쓰기·참조·트리거 권한을 확인하고 위험하거나 확인 불가하면
거부한다. 이 검사는 실제 계정의 전체 권한 검토를 대체하지 않는다.

### 전체 조회 범위 검증과 승인 조건

계정 위험 검사와 조회 범위 검증은 별도 단계다. 세 테이블 각각에서
스키마 USAGE와 필수 열의 SELECT를 카탈로그로 확인한다. 지원 범위는
상속 자식이 없는 일반 테이블이다. RLS가 설정된 테이블에는 현재 전용
역할에만 지정된 permissive SELECT 정책 `jb_ai_report_full_read`가
필요하다. 정책의 USING은 리터럴 true여야 한다. 현재 역할, 상속된 역할
또는 PUBLIC에 적용되는 restrictive SELECT/ALL 정책이 하나라도 있으면
전체 범위를 입증할 수 없으므로 거부한다. RLS를 끄거나 우회하지 않는다.
COUNT와 키셋 페이지 비교는 이 검사 이후에만 사용한다.

컨트롤타워가 세 테이블의 전체 보고 범위를 명시적으로 승인하기 전에는
DB 연결을 사용하지 않는다. 정책 설계 후보는 승인된 읽기 전용 역할에만
필수 열 SELECT와 스키마 USAGE를 주고, 해당 역할에 한해 세 테이블에
위 이름의 SELECT USING (true) 정책을 두는 방식이다. RLS 활성 상태,
기존 앱 역할과 정책을 유지하며 PUBLIC 및 앱 사용자에게 새 권한을 주지
않는다. 다른 테이블이나 제한된 행 범위를 승인할 경우 별도 계약이 필요하다.
현재 DB에는 정책이나 계정을 적용하지 않았다.

실제 연결 전 승인된 계정의 권한 전체, TLS, 드라이버·pooler 호환성,
카탈로그 제약 표현, 토큰 검증을 확인한다. 잘못된 계정/DSN 설정과 TLS
설정 오류는 분리하고, 대표적인 DB 로그인 및 인증서 검증 실패는 내부
상태로 구분한다. 독립 배정 원장은 연결하지 않았으며 이력이 없는 담당자를
확정 실적에 넣지 않는다.
현재 테스트는 합성 응답과 모의 드라이버만 사용한다.

```sh
node --test JB_*/daily-{task-time,task-adapter,report-preview,report-server,report-jb-dev}.test.mjs
```

## 전 직원 통합보고

`createJbDevIntegratedDailyReportReader()`는 호출 건당 토큰 검증 한 번과
읽기 전용 스냅샷 한 번을 사용한다. 활성 owner 확인 후 직원 디렉터리,
업무, 이력의 독립 건수와 전체 페이지를 같은 트랜잭션에서 읽는다.
개별 조회를 반복하지 않으며 기존 개인 보고 인터페이스도 유지한다.
전 직원 모드에는 기존 권한 외에 `jb_employees.name`과
`jb_tasks.title`의 열 SELECT가 필요하다. 두 필드의 문자열 타입과
권한을 검증한다. 권한 부여나 기존 정책 변경은 이 작업에 포함되지 않는다.

입력 확장 `jb-report-presentation-v1`은 기존 업무 페이지에 title을
포함하고, 같은 스냅샷의 직원 ID와 표시명 페이지를 추가한다. 합계 전에
직원 페이지와 원본 범위 전체를 검사한다. 확정 담당, 현재 담당만 확인,
담당 미지정·직원 정보 미확인 업무는 서로 겹치지 않게 배치한다. 기존
완료 업무와 당일 관련이 없는 업무는 일일 합계에서 분리한다. 전체 업무의
상태 건수와 확정 담당 기준 건수는 별도 필드다. 시간 기준은 업무 상태다.

출력 `jb-integrated-daily-report-v1`의 `sources`는 각 원본 시스템의
`system`, `checkedAt`(UTC 또는 null), `status`를 갖는다. 업무 원본
식별자는 `(sourceSystem, sourceTaskId)`의 조합이다. Notion과
NAVER WORKS는 `not_connected`이며 현재 업무·시간·합계에 기여하지
않는다. 추후 추가될 원본은 별도 조회 상태와 범위를 유지하고, 원본 간
동일 업무라는 검증 근거와 합산 계약을 승인하기 전에는 원본별 집계를
별도로 유지한다. `summaryInput`은 JB 원본 집계와 시간 기준만 담은
구조화 입력이다. 요약은 검증용 규칙 기반이며 AI 호출은 없다.

개발용 미리보기는 로컬 합성 응답으로만 이 출력 계약을 렌더링한다.
승인된 서버 연결은 서버 측 호출 결과를 전달하는 별도 경로이며 현재
브라우저에서 선택하거나 호출할 네트워크 연결과 HTTP API는 없다.
