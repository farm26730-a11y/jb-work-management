# 운영 배포 최종 확인 · 2026-11-22 KST

**판정: 배포 보류.** 운영 백업·Storage 복구 증거, Netlify의 현재 자동 게시 설정, JB-DEV 실연동 검증이 남아 있다. 운영 main 병합, 운영 SQL 설치, Netlify 게시 또는 롤백 실행은 하지 않았다. 앱 기준은 `c006b4ac2d31fb15accb29ba80d1a03eb52ea18c`이며 이번 변경은 이 보고서와 [사전 감사 정정](README.md)이다.

## 1. 운영 Supabase 백업 및 Storage

- 프로젝트 `bnonnvgtbukztfhaxgrr`의 Management API 백업 목록 요청은 HTTP 401을 반환했다. 현재 연결 도구에는 백업 목록·복구 이력 열람 기능이 없다. 백업 ID, 완료 시각, 보존 기간/PITR 범위 및 실제 복구 가능 여부는 **미확인**이다.
- 프로젝트의 Backups/PITR를 열람할 수 있는 Supabase 조직 또는 프로젝트 관리자 권한이 필요하다. 관리자 확인 경로는 [운영 프로젝트 Dashboard](https://supabase.com/dashboard/project/bnonnvgtbukztfhaxgrr) → Database → Backups다. 최근 성공 백업의 ID·완료 시각·보존 기간과 복구 선택 가능 여부를 기록한다. 실제 복원 검증은 운영 대신 별도 격리 환경에서 승인된 절차로 진행한다.
- Supabase DB 백업에는 Storage 객체의 실제 파일이 포함되지 않는다. 운영 `jb-task-images`의 별도 객체 백업 ID/저장 위치·완료 시각·파일 목록·표본 복원 결과를 백업 담당자와 확인해야 한다. 이전 감사의 Storage 메타데이터 179건은 백업 증거가 아니다. 실제 Storage 백업은 **미확인**이다. [Supabase 백업 문서](https://supabase.com/docs/guides/platform/backups)

## 2. Netlify Published Deploy와 복구

| 공개 API에서 확인 | 값 |
|---|---|
| 운영 사이트 | `melodic-cendol-36fe76` · Site ID `411c3bed-cd5c-4d69-9fd7-06a54ab165e9` |
| 현재 Published Deploy | `6af81282e352dd18111e2182` · ready · production · main |
| 운영 커밋 및 게시 시각 | `4ef635495e65f81e6613224f1848f2efe8fa628a` · 2026-11-14 16:49:38 KST |
| 직전 운영 게시 기록 | `6af8127629d70a0b4788cf2e` · ready · main · `26c040fcbb71c39d035d85113027e339e2819a77` · 2026-11-14 16:49:21 KST |
| 이전 PR 자동 미리보기 이력 | `6b0248df84eba994f43013c7` · deploy-preview · 운영 게시 시각 없음 |
| 개발 사이트 게시 기록 | `6afaafc026b8f0c465bbf9b7` · development-test · `4c037b0a2e72bcb703e225d3316fb45b6e7bfc83` · 페이지 요청은 HTTP 401 |

운영 사이트의 공개 HTML은 main 파일과 바이트 단위로 동일하다. 공개 API의 build_settings는 비어 있다. 현재 설정상의 Production branch, Git push 자동 게시, Deploy Preview/branch deploy, Build hooks, 자동 게시 잠금 상태는 **미확인**이다. 게시 이력에서 운영 배포의 가지가 main인 점은 직접 확인했다. 현재 설정까지 확인하려면 Netlify 운영 프로젝트의 빌드·배포 설정 열람 권한이 필요하다. 관리 경로는 [운영 프로젝트](https://app.netlify.com/projects/melodic-cendol-36fe76) → Project configuration → Build & deploy → Continuous deployment의 Repository, Branches and deploy contexts, Build hooks 및 Deploys의 게시 잠금 상태다. 공개 API의 [운영 사이트](https://api.netlify.com/api/v1/sites/melodic-cendol-36fe76.netlify.app)와 [배포 목록](https://api.netlify.com/api/v1/sites/411c3bed-cd5c-4d69-9fd7-06a54ab165e9/deploys?per_page=10)을 조회했다.

복구 절차: 신규 운영 게시 직전의 정상 버전으로 현재 확인한 `6af81282e352dd18111e2182`를 기록한다. 게시 직전 다시 조회하고 달라졌으면 실제 Published Deploy ID로 갱신한다. 장애 시 승인된 운영 담당자가 Deploys → 해당 정상 배포 상세 → Publish deploy를 실행해 운영 도메인에 재게시한다. Published ID·운영 파일·주요 기능을 재검증하고 필요 시 Git 상태를 정합화한다. 이전 게시 이력 `6af8127629d70a0b4788cf2e`는 기록상 ready이며 별도 기능 시험은 미실행이다. 이 절차는 앱 복구이며 DB 복구는 별도 승인 대상이다. [현재 운영 배포 상세](https://app.netlify.com/projects/melodic-cendol-36fe76/deploys/6af81282e352dd18111e2182)

## 3. JB-DEV 권한 및 실연동 시험

- 읽기 전용 조회에서 인증 계정 총 1개와 활성 대표(owner) 연결 1개를 확인했다. 활성 부서장·직원 테스트 로그인 연결은 0개다. 승인된 테스트 로그인 세션을 확보하지 못했다.
- JB-DEV의 현재 보고 댓글 ID RPC는 SECURITY INVOKER이고 authenticated의 내부 보고 코어 실행 권한이 없다. 따라서 권한 확대 없이 준비된 [개발 호환 RPC 제안](../comment-photo-fix/jb-dev-report-rpc-proposal.sql)의 검토·적용이 사진 포함 보고의 실제 검증 선행조건이다. 이번에 설치하지 않았다.
- **미검증**: 실제 대표·부서장·직원 권한별 로그인, 사진 저장 → Storage 및 DB 기록 → 재조회 → 삭제, 상급자 확인 및 대표 직접 보고, 실제 푸시 수신. 이전 Chromium 모의 검증과 격리 SQL 시험은 실연동 통과로 계산하지 않는다.
- 필요한 접근: JB-DEV에만 연결된 대표·부서장·직원 전용 테스트 계정과 안전한 로그인 세션, 가상 업무·사진, 호환 RPC가 있는 JB-DEV 환경, JB-DEV만 연결된 Functions/PWA와 푸시를 받을 테스트 기기. 개발 사이트 현재 게시본은 후보와 다르므로 후보 SHA가 검증 환경에서 실제 로드됐는지 확인해야 한다. 비밀번호·비밀키는 보고서나 공개 저장소에 저장하지 않는다.

## 최종 운영 배포 승인 요청서 · 집행 대기

선행 조건은 복구 가능한 운영 DB·객체 백업 확인, Netlify 자동 게시 조건과 복구 대상 재확인, JB-DEV 실연동 통과, 배포 직전 데이터 기준선 재수집이다. 완료 시 다음 두 항목을 별도로 승인받는다.

1. 운영 Supabase `bnonnvgtbukztfhaxgrr`의 [신규 RPC 설치안](../report-comment-id-install.sql) 적용. SQL SHA-256 `f8a7140ae415b18e2225ec6defe988d8441728f0f17eb4026d30fa66b96fe82a`. 기존 행 및 Storage 정책 변경은 포함하지 않는다.
2. `release/jb-operations-readiness-20261122`의 최종 승인 SHA에서 확인한 앱 변경을 운영 main에 반영하고 `melodic-cendol-36fe76`에 승인 시각에 게시. main 병합으로 자동 게시될 수 있으므로 두 동작을 함께 승인한다. 실패 시 직전 정상 Deploy ID로 복구하고 DB 롤백은 별도로 판단한다.

이 문서는 집행 승인을 대신하지 않는다.
