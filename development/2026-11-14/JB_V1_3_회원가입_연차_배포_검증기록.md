# JB 업무관리 V1.3 — 2026-11-14 회원가입 관리·연차 기능 운영 반영 기록

## 사용자 요청 및 오류 원인
- 사용자 화면: 대표 홈 '가입 요청 조회 실패: Failed to fetch', 확인 요청 0건.
- 확인한 브라우저 탭: `file:///C:/Users/user/Desktop/.../index12.html`. 로컬 파일을 실행하면 앱의 `/.netlify/functions/account-admin` 엔드포인트에 접속할 수 없음.
- 기존 운영 `main`에 `netlify/functions/account-admin.mjs` 파일 자체가 없었음.
- Netlify 프로젝트가 공개하는 운영 주소(연결된 사이트): `https://melodic-cendol-36fe76.netlify.app/`.
- 홈페이지의 요청 0건은 계정 조회 실패 상황에서는 실제 미연결 계정이 없음을 보증하지 않음.

## GitHub 운영 반영
- 운영 브랜치: `main`.
- 안전한 배포 커밋: `bdf4f3e192311f70296775f95f367f4a957dc1f2`.
- `main`의 기존 커밋 `c84e3d7cdaa986cfe8f75f95f367f4a957dc1f2`가 아니라 실제 선행 SHA `c84e3d7cdaa986cfe8f75d1bf5e7025a39880087`를 부모로 하여 두 파일만 선별 반영함.
- 두 브랜치가 diverged(개발 93 ahead / 14 behind)라 전체 강제 복사/병합을 피함.
- 변경 1: `JB_97EBB4B4EBAC_V1_3_A1EAB89DECA0A7EBB7A6ED8C9DEDB88BEC9CB2ECA4B9EDA882EC80/index.html` (개발 소스 blob `9038b46334a3777c901c0b28e38877ccc58afd56`)
- 변경 2: `JB_97EBB4B4EBAC_V1_3_A1EAB89DECA0A7EBB7A6ED8C9DEDB88BEC9CB2ECA4B9EDA882EC80/netlify/functions/account-admin.mjs` (개발 소스 blob `7b989d96f5d05666822910c3883cbe0dd5f39ac0`)
- 나머지 운영 `sw.js`, `netlify.toml`, `package.json`, 기존 push 함수, 아이콘, manifest 파일은 main과 development-test에서 해시 동일하여 불변.
- 계정 관리 백엔드에는 JWT/active owner 또는 manager 확인, 매니저 소속 부서 직원만 기존 계정 연결·해제하도록 제한.

## 운영 Supabase
- 프로젝트 `bnonnvgtbukztfhaxgrr` 사용.
- 기존 연차 RPC 7개와 인사 장부 사용.
- 추가 마이그레이션 `20261114062548 / jb_signup_manager_department_guard_20261114` 적용.
- 기능 `jb_link_staff_by_email_v24`에서 관리자 신규 직원은 자신과 같은 부서로만 등록 가능. 대표는 기존대로 전체 부서.
- 기존 직원 데이터 삭제/재등록/전체 초기화 수행하지 않음.

## 실제 확인한 시험
- [x] 운영 main 최신 커밋 `bdf4f3e192311f70296775f95f367f4a957dc1f2` 확인.
- [x] main의 HTML, account-admin 파일이 각각 예상 GitHub blob SHA와 동일함.
- [x] 전체 HTML 4개 인라인 실행 스크립트 JS 구문 검사.
- [x] 로컬 file://에서 안내 메시지 표시 모의시험, HTTPS 환경에서 Netlify 함수 fetch 모의시험.
- [x] 관리자 부서 권한 / 대표 조회 권한 등 서버 코드 함수 단위 모의시험.
- [x] 이전 main 초기화 UI 안전 응답 검증 부분 유지 및 V1.3 표기 확인.
- [x] 연차 조회 탭/후속 RPC 호출 코드 정적 확인.
- [x] 운영 Supabase 신규 관리자 소속 부서 제한 설치 및 DB 함수 정의 재검사.
- [ ] Netlify **실제 새 커밋 게시 확인**: 연결된 프로젝트의 읽기 전용 overview에서 여전히 '현재 게시됨: hotfix... (11월 13일)' 상태. 이 뷰가 자동 갱신되지 않는 상태일 수 있으므로 실제 Deploys 탭에서 상태 확인 필요.
- [ ] Netlify 환경변수 `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_PUBLISHABLE_KEY` (서비스 역할키는 서버 측만 보관) 존재 여부 확인.
- [ ] 운영 Netlify HTTPS 주소에서 대표/관리자 실계정 가입 요청 조회 및 신규 직원 연결 통합시험.
- [ ] 실제 입사일/연차 발생/사용 차감/취소·변경 및 갤럭시 실기기 시험.
- [ ] 17명 직원 중 연차 등록 내역 및 감사 기록 대사 후 사용 개시. (조회 시점 연차 발생 장부 6건, 연차 승인 검토 0건. 이 수치는 계속 변할 수 있음.)

## 특별 주의
- 로컬 HTML (file://)에서 회원가입 관리·서버 함수를 테스트하지 말고 배포된 HTTPS Netlify 사이트를 사용.
- Netlify가 GitHub main으로 자동 배포하는지는 `https://app.netlify.com/projects/melodic-cendol-36fe76/deploys`에서 마지막 배포 커밋 확인.
- 개발 계정/프론트에 service role 키를 넣거나 노출하지 않음.
- 연차 전용 장부가 활성화됐으므로 '운영 기록 전체 초기화' 실행은 기존 신청 기록과 인사 장부의 불일치를 낼 수 있음. 장부 백업·사용 기록 보존 기능 보완 전에는 실행 금지.
- 연차 자동 승인 관리자 본인 경로와 법정 예외(80% 미만, 연차 이월/소멸, 휴직 등)는 여전히 실계정 검증 전.
