# JB 업무관리 V1.3 — 대표님 운영 기록 초기화 오류 재점검

점검일: 2026-11-13
운영 Supabase: `bnonnvgtbukztfhaxgrr`
개발 브랜치: `development-test`
운영 브랜치: `main` (이 점검에서는 갱신하지 않음)

## 1. 오류와 기존 수정 확인

과거 대표님 초기화 실패 오류: `cannot truncate a table referenced in a foreign key constraint`.
기존 초기화 대상 15개에서 신규 업무 지시 확인 및 댓글 확인 테이블이 누락되어 발생.

누락된 테이블:
- `public.jb_task_assignment_ack_v13`
- `public.jb_task_comment_attention_v13`
- 식사 신청 및 주문 등 추가 운영 테이블도 대상 범위 확인

운영 DB에서 직접 조회한 현재 함수는 `public.jb_owner_reset_operations_v11(p_phrase text,p_backup_confirmed boolean)`이며,
정확히 21개 운영 테이블 삭제 및 8개 기준 정보 보존으로 이미 수정돼 있음.
운영 프로젝트 migration history에 `20261113074937 / jb_owner_reset_operations_fk_complete_20261113` 기록 확인.
함수 설치 SQL은 `development/2026-11-13/JB_V1_3_운영기록초기화_21개_외래키보완.sql`에 보관됨.

## 2. 재점검 결과 (운영 DB, 읽기 전용)

| 점검 항목 | 결과 |
| --- | --- |
| `public.jb_*` 전체 일반/파티션 테이블 | 29개 |
| 함수의 운영 기록 초기화 대상 | 21개 |
| 보존 대상 기준 테이블 | 8개 |
| 대상/보존 분류 외 미지정 테이블 | 0개 |
| 초기화 대상 부모 테이블을 외부에서 참조하는 FK | 0개 |
| 초기화 대상의 사용자 정의 ON TRUNCATE 트리거 | 0개 |
| `jb_*` 파티션 상속 관계 | 0개 |
| 유사한 초기화/TRUNCATE 업무 함수 | 별도 발견되지 않음 |
| 함수 소유자/실행 | postgres 소유 SECURITY DEFINER / authenticated EXECUTE, 내부 재직 owner 재검증 |
| 기존 기록이 현재 보존되는지 | 업무 14건, 댓글 11건, 업무 확인 1건, 댓글 확인 3건, 직원 14명 조회됨 |

**주의:** 위 결과는 읽기 전용 검사이며 실제 `TRUNCATE`나 대표 계정 RPC 실행을 하지 않았다.
따라서 운영 사이트에서의 실제 초기화 성공 여부는 아직 검증되지 않음.

## 3. 보호 및 향후 장애 방지

현재 서버 함수는
- `owner`·재직 중인 계정과 백업 확인 및 정확한 문구 검사
- Advisory lock으로 중복 진행 직렬화
- 새 `jb_*` 테이블이 삭제/보존 목록에서 누락되면 중단
- 모든 스키마를 포함한 외래키를 검사하고 대상 외부 참조가 생기면 중단
- `TRUNCATE ... RESTRICT`로 CASCADE 강제삭제 방지
- `auth.users`, 직원·부서·연락처·업무 템플릿·푸시 구독·고정 식사 인원·설정 등 보존
- Storage 실제 파일 삭제를 수행하지 않음

## 4. 개발 UI 안전성 보완

`development-test`의 전체 HTML에 다음 사항 추가:
- 초기화 RPC의 `success:true` 응답을 확인한 뒤 성공 문구 표시
- 응답에서 실제 대상 테이블 수 및 보존 테이블 수 확인
- 예상과 다른 응답이면 완료/실패를 단정하지 않고 중복 실행 금지를 표시
- 초기화 후 `loadData`로 화면이 다시 만들어져도 확인 메시지 유지
- 초기화 응답 성공과 목록 재조회 오류를 구분하여 표시

전체 HTML 인라인 실행 스크립트 4개 JavaScript 구문 검사 통과.
실제 운영 데이터 초기화는 하지 않았으므로 사용자 로그인 및 통합 시험은 별도.

## 5. 최종 시험 항목

- [x] 운영 함수 설치 및 권한 정의 확인
- [x] 29개 테이블/21개 초기화/8개 보존 분류 확인
- [x] 전체 스키마 외래키/트리거/상속 관계 검사
- [x] 실행형 JavaScript 구문 검사
- [ ] 실제 대표님 계정에서 초기화 버튼 동작 (데이터 삭제 발생하므로 사용자 측 사전 백업 후 진행)
- [ ] 갤럭시에서 결과 메시지 지속 표시 확인
- [ ] 필요 시 `development-test`의 안전 UI 변경분 검증 후 별도 운영 적용
