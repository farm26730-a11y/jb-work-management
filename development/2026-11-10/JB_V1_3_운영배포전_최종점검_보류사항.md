# JB 업무관리 V1.3 — 배포 전 최종 점검 (2026-11-10)

## 결론
**아직 운영 배포 보류.** 실제 회원가입·메일 인증은 확인되었고 개발 코드의 구문·서버 DB 요소·정적 파일은 통과했지만, 신규 직원의 첫 접속 자동연결 기능을 위한 Netlify 공개 환경변수와 실제 새 기기·푸시 테스트가 남아 있음.

## 현재 확인된 내용
- GitHub `farm26730-a11y/jb-work-management`: 운영 `main`, 시험 `development-test`. 비교 결과 `diverged` (개발이 main 대비 48 ahead, 5 behind — 점검 시점). **무검증 전체 덮어쓰기 금지**.
- 운영 Netlify: `https://melodic-cendol-36fe76.netlify.app/` (Netlify 프로젝트에서 GitHub 연결 확인).
- 운영 Supabase 프로젝트 ID: `bnonnvgtbukztfhaxgrr` (`https://bnonnvgtbukztfhaxgrr.supabase.co`).
- 인증 로그 2026-11-10 오후 3:49(KST) `/signup` 200, 3:50(KST) `/verify` 303, 4:16(KST) `/token` 200. 사용자 개인정보는 문서에 기재하지 않음.
- 신규 가입·메일 인증·기존 로그인 시험 성공(서버 로그). 사용자 측 기능 이상 없음 확인.
- 기존 2026-11-10 13:09경 `429 over_email_send_rate_limit`은 SMTP 전환 전 기록.
- 운영 Auth 10건 중 인증 완료 9건(조회 시점). 기존 미인증 계정은 유지.
- 운영 DB: `jb_task_assignment_ack_v13`, `jb_task_comment_attention_v13`, `jb_task_images`, `jb_task_report_requests`, `jb_push_outbox`, `jb_push_subscriptions`, `jb_meal_regular_people_v15` 존재.
- 필수 RPC `jb_meal_regular_add_staff_v13`, `jb_acknowledge_task_comment_v13`, `jb_acknowledge_assigned_task_v13`, `jb_submit_report_core_v14`, `jb_link_staff_by_email_v24` 등 존재.
- `jb_task_images.comment_id` nullable FK -> `jb_task_comments(id)`, ON DELETE SET NULL 확인.
- 댓글/보고/업무 할당 트리거 활성, 대상 테이블 RLS 활성.
- 최신 개발 HTML inline JS 4개 구문 검사 통과. 보고 즉시 호출 4개, 댓글 즉시 호출 1개, 업무 지시 즉시 호출 1개, 식사 마감시간 '저녁 신청' 화면만 노출 코드 확인.
- 빌드 명령에서 복사하는 index/SW/manifest/아이콘 파일 전부 존재. Netlify 푸시/공개 설정 함수 파일 존재.

## 배포 전 발견한 오류와 개발용 수정
- 기존: 최초 접속 기기에 `localStorage`의 Supabase URL/publishable key가 없으면 업무관리 로그인 대신 개발자용 수동 서버 설정 화면이 표시됨.
- 개발 브랜치에서 자동 공개 연결 조회를 추가함.
  - 신규 `netlify/functions/public-config.mjs`: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` 환경변수 중 공개 주소와 **sb_publishable_ 공개키**만 반환.
  - `index.html`: HTTPS 사이트 접속 시 공개 설정을 먼저 조회하여, 이전에 저장된 잘못된 프로젝트 설정을 운영 환경 변수로 대체하고 자동 로그인 화면 구동. 로컬 파일 테스트에선 수동 연결 UI를 유지.
  - 서버 role/secret/VAPID 비밀키 노출 없음.
  - 공개 설정 모의시험 14/14 통과 (첫 접속, 로컬, 환경변수 없음, 잘못된 키 거부, 저장된 설정 대체, HTML JS 4개 포함).
- **반드시 Netlify 운영 프로젝트에서 `SUPABASE_PUBLISHABLE_KEY` 환경변수 등록 필요**. 해당 환경변수가 없으면 새 기기에서 여전히 수동 연결 화면이 보임.

## 반드시 배포 전에 확인할 사항
1. Netlify `melodic-cendol-36fe76` → Project configuration → Environment variables → **`SUPABASE_PUBLISHABLE_KEY`** (운영 Supabase `sb_publishable_...` 값, 공개키) 등록. `SUPABASE_URL`은 운영 Supabase 주소와 일치해야 함. `SERVICE_ROLE_KEY`는 절대 HTML/공개키 변수에 입력하지 말 것.
2. Netlify Build settings에서 **Base directory**가 `JB_97EBB4B4EBAC_V1_3_A1EAB89DECA0A7EBB7A6ED8C9DEDB88BEC9CB2ECA4B9EDA882EC80` 폴더를 가리키고, 기존 네임서버/배포 URL을 그대로 유지하는지 확인.
3. 운영 `main`과 개발 변경사항을 diff 후 선택적으로 반영; 시험 SQL 중 '사용 중단 / 실행 금지' 파일은 **절대 실행하지 않음**. 운영 DB에서 필수 스키마 대부분 존재하므로 **추가 SQL 없음**.
4. 신규 브라우저/삼성 Galaxy에서 localStorage 없는 상태로 서버 설정 화면 없이 로그인·회원가입이 뜨는지 테스트.
5. 대표/관리자/일반 직원 실제 계정으로 신규 업무/댓글/보고 알림 수신, 시간차, 한 댓글 3중 알림 재발 여부 측정.
6. Netlify Scheduled function `push-dispatch` 매분 예약이 실제 배포 함수 화면에 나타나는지, `push-now`, `public-config`가 실제 동작하는지 확인. 실제 푸시 구독 등록 직원 수는 운영 DB 기준 3명(구독 4개)로 전 직원에 걸친 알림 수신 검증 불가.
7. 비밀번호 재설정 메일, 인증 메일 재발송, 잘못된 인증 링크, 로그아웃 후 계정 변경, 홈 권한 확인, 식사 신청 마감시간 07:00 경계 시험.
8. DB 및 사진 저장소 백업/롤백 준비 후 공식 배포를 판단할 것.

## 참고
- Netlify Scheduled Functions는 published deploy에서만 cron 실행, 30초 제한(공식 Netlify Docs).
- `package.json`에 semver 범위가 있고 lock file이 확인되지 않아 의존성 고정/빌드 로그 확인 권장.
- 실제 Netlify 프로덕션 환경변수/배포 빌드/기기 푸시 로그는 직접 검증하지 못함.

## 현재 조치
`development-test`만 수정. 운영 GitHub `main` 변경 없음. Netlify 재배포 없음. 운영 DB/데이터 SQL 변경 없음. V1.3 유지.
