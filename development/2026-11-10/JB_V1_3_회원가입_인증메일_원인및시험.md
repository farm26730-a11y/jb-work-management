# JB 업무관리 V1.3 — 회원가입·이메일 인증 점검 (2026-11-10)

## 증상
회원가입 후 이메일 인증을 완료할 수 없거나 메일이 보이지 않는다는 보고.

## 조회로 확인한 사실 (운영 Supabase, 데이터 변경 없음)
- 프로젝트 `bnonnvgtbukztfhaxgrr` Auth 로그에서 2026-11-10 04:09:44~47 UTC `/signup` 요청의 429 / `over_email_send_rate_limit` 확인.
- 같은 날 확인 이메일 `mail.send` 기록 및 `/signup` 200 기록 존재. 발신자는 Supabase 기본 SMTP `noreply@mail.app.supabase.io`.
- Auth 계정 10건 중 인증 완료 8건, 미인증 2건. 미인증 2건 모두 최근 24시간 내 생성되었고 인증메일 발송 시도 시간 기록이 있음.
- 직원 테이블에 연결된 직원 계정은 8건. 가입·인증·직원 연결은 서로 다른 단계.
- 인증 로그의 최근 테스트 요청 Referer가 `http://localhost:3000`으로 확인됨. 이것만으로 Supabase 사이트 URL 구성 자체가 localhost라고 단정할 수는 없음.
- 운영 DB의 `jb_link_staff_by_email_v24`는 인증된 `auth.users.email_confirmed_at`이 있는 사용자를 대표/관리자 권한으로 일반 직원에 연결하도록 구현되어 있음.
- 확인 메일의 `mail.send` 기록은 수신자 메일함 도달을 보장하지 않음.

## 공식 문서 기준 서버 원인
- Supabase 기본 메일 서비스는 시간당 프로젝트 전체 2통 제한이고 프로젝트 팀 이메일 주소로만 발송 가능.
- 일반 직원의 주소로 운영하려면 사용자 지정 SMTP 또는 Send Email Hook 구성 필요.
- 회원가입 후 이동하는 공식 Site URL과 Redirect URL은 Authentication → URL Configuration에서 등록 필요.
- 인증을 비활성화해 우회하지 말 것. 이메일 미확인 계정을 수동 승인하거나 비밀번호를 노출하지 말 것.

## development-test의 HTML 변경
- 메일 발송량 초과(429)와 발신 대상 미허용 오류를 사용자가 구별하도록 안내
- `auth.resend({type:'signup'})`을 이용한 인증 메일 재발송 UI; 요청 후 앱 차원 60초 중복 클릭 제한. Supabase 자체 제한은 별도 적용됨
- 인증 링크 오류(예: OTP 만료) 안내
- `file://`/localhost에서 회원가입 시 이메일 인증 링크가 잘못된 사이트로 이동하지 않도록 HTTPS 배포 앱 사용 안내 및 가입 차단
- 가입 API 성공을 실제 메일함 수신 성공으로 표현하지 않음
- 인증 완료 이후에도 직원 계정 연결 전 앱 데이터 접근을 허용하지 않는 기존 구조 보존
- 기존 로그인/업무·근태·식사·보고 기능과 서버 SQL 변경 없음
- 테스트 브랜치에서만 수정, `main`·Netlify 운영 배포 변경 없음

## 시험
- 전체 HTML JavaScript 4개 블록 구문 검증 통과
- 순수 모의시험 11/11: 429 오류 설명, 승인되지 않은 수신자 설명, HTTPS 리다이렉트 사용, 로컬 파일 방지, 만료 링크 설명, 재발송 연속 클릭 제한, 메일 도착 성공으로 오인하지 않음
- 실제 SMTP 연결/기기별 메일 수신/링크 검증은 수행하지 않았음

## 운영 반영 전 필수 단계
1. Supabase Dashboard → Authentication → SMTP Settings에서 회사가 관리하는 SMTP 공급자(호스트, 포트, 사용자명, 비밀번호, 발신 이메일) 등록. 비밀번호를 HTML/GitHub에 저장하지 않음.
2. Authentication → URL Configuration의 Site URL 및 Redirect URLs를 실제 운영 Netlify HTTPS 주소로 정렬. 도메인이 여러 개인 경우 인증 링크 대상과 실제 접근 주소 일치.
3. Authentication → Sign In / Providers에서 이메일 가입/확인 정책 점검(확인 필수 유지).
4. 새 테스트 계정 1개로 가입→메일 전송→인증 링크→Auth confirmed 시각→대표/관리자 직원 연결→정상 로그인까지 실제 검증.
5. 기존 미인증 두 건은 삭제하지 않고 서버 SMTP 구성을 마친 뒤 필요 시 인증 메일 재발송.
6. `main` 코드와 개발본 차이 검토 후 명시적 배포 결정; 개발 브랜치 일괄 덮어쓰기 금지.

## SQL
추가 SQL 없음. 운영 DB 수정 없음.

## 결과
**원인 식별: 확인됨. 코드 오류 안내 개선: 개발용 완료. 실제 메일 정상 수신: SMTP 미설정으로 미확인.**
