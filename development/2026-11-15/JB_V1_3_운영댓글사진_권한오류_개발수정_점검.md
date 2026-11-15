# JB 업무관리 V1.3 — 운영 댓글 사진 등록 오류 분석 및 개발용 수정
기록일: 2026-11-15

## 2026-11-15 사용자 요구 재확인 — **다른 직원의 업무에도 댓글과 사진 허용**

**개발의 정식 권한 규칙:** 로그인한 활성 대표/관리자/직원은 타인이 담당하거나 등록한 업무에서도 본인 이름으로 댓글을 작성할 수 있고, 그 **내가 작성한 댓글**에 사진을 첨부할 수 있습니다. 댓글을 다는 데 업무 담당자·등록자·부서 일치 조건을 걸지 않습니다.

- `본인 댓글에 첨부 가능`에서 **본인**은 업무 담당자가 아니라 **댓글 작성자**를 뜻함.
- 다른 직원의 댓글을 임의로 수정하거나 사진을 끼워 넣는 권한과는 별개이며, 해당 제한은 유지.
- 개발 RLS `jb_task_comments_insert_active_staff`는 작성자의 활성 계정과 **업무 존재**만 확인함; `assignee_id` 또는 동일 부서 조건 없음.
- 개발 사진 경로 `taskId/comments/commentId/fileId.jpg`에 대한 `jb_comment_photo_can_upload_v13`도 현재 사용자=댓글 작성자인지와 해당 댓글이 업무에 소속됐는지만 확인함. **업무 담당자/등록자/부서 확인 없음.**
- UI는 홈 → 다른 직원 → 해당 업무 → 상세 보기에서도 새 댓글+사진 입력 폼을 노출하며 담당자 여부로 숨기지 않음.
- 화면에 이 규칙을 명시한 개발 HTML 커밋: `00b2167f0d0a4171b69f6cf75bfc5457df222675`.
- 테스트용 다른 직원의 업무를 대상으로 `staff / manager / owner` 각 역할에서 댓글 INSERT 및 사진의 동일 commentId 연결까지 **코드 모의시험 3/3 통과**. 실계정, 브라우저, 갤럭시, 실제 Storage 전송 **아직 미검증**.
- **운영 main과 운영 Supabase는 이번 사용자 명시 요구로 변경하지 않음.**

## 환경 및 변경 금지 범위
- 사용자는 이 채팅을 **개발용**으로 지정했음.
- GitHub `development-test` + Supabase `JB-DEV` (`apkrhhdmjxbvwtdktfaq`)만 수정.
- GitHub `main` + 운영 Supabase `bnonnvgtbukztfhaxgrr` **쓰기 변경 없음**. 운영 배포 미진행.
- Netlify 개발용 사이트: `https://shiny-lollipop-c8c0fb.netlify.app` 자동 배포가 설정되어 있으나 최신 해당 커밋의 Netlify Published 여부는 확인하지 못함.

## 원인(운영 read-only 검사)
1. 운영 코드: `jbUploadTaskAttachments()`가 `jb-task-images` 저장소에 먼저 파일을 올린 뒤, `public.jb_task_images`에 사진 기록과 `comment_id`를 저장.
2. 운영 권한: Storage INSERT RLS가 `public.jb_photo_can_upload(split_part(name,'/',1))`을 호출. 이 함수는 **대표**, **업무와 같은 부서 관리자**, **업무 담당 직원**에게만 업로드를 허용. 댓글 작성 가능한 범위보다 좁고 **업무 지시자(created_by)**도 별도로 허용하지 않음.
3. `jb_task_images` INSERT RLS도 동일한 함수로 차단됨.
4. 2026-11-15 조회 시 운영 댓글 총 7건 중 6건은 댓글 작성자 기준 업로드 자격 없음(직원 3건, 관리자 3건); 댓글에 연결된 사진 기록 `comment_id IS NOT NULL` 0건. 위 수치는 당시 스냅샷이며 운영 중 변경될 수 있음.
5. `jb_submit_report_core_v14`는 실제 생성된 `v_comment_id` 대신 **보고 요청 ID**를 반환. 운영 프런트에서는 보고 후 작성자/본문/작성시각으로 댓글을 재검색하므로 동시에 동일 댓글을 올리면 다른 댓글에 사진을 연결할 위험이 있음.
6. 운영 사진 저장소 객체 수가 사진 기록보다 약 30개 많아, 기록 없는 파일이 존재함. 원인은 과거 삭제·업로드 실패 등 복수 가능성이 있으므로 단정하지 않고 무단 삭제 금지.
7. 조회 당시 업무별 사진은 최대 4장(제한 5장), 댓글 업무의 5장 제한 도달 건은 0건. 권한 불일치가 주요 발견사항.
8. 실제 사용자 기기 브라우저에서 재현한 로그/정확한 오류 문구는 아직 없음.

## JB-DEV 적용 사항
### SQL — 본인이 작성한 댓글만 업로드 가능
- 파일: `development/2026-11-15/JB_V1_3_댓글사진_작성자권한_추가.sql`
- 마이그레이션: `jb_v13_comment_photo_author_isolation_20261115`, `jb_v13_comment_photo_filename_regex_guard_20261115`
- `public.jb_comment_photo_can_upload_v13(p_storage_path)` 신규 함수. 경로 구조 `{taskId}/comments/{commentId}/{fileUuid}.jpg|jpeg|png|webp` 엄격 확인.
- 인증된 활성 직원이 해당 `commentId`의 **원래 작성자**이고 `comment.task_id = taskId`일 때만 허용.
- Storage `jb_comment_photo_insert_v13`, 사진 DB INSERT `jb_comment_image_record_insert_v13`의 permissive 정책 추가.
- RESTRICTIVE 정책 `jb_comment_image_record_author_guard_v13`으로 기존 관리자/대표의 다른 직원 댓글에 사진 임의 첨부 방지.
- 기존 독립 업무 사진(`comment_id=null`) 업로드 경로/권한 유지.
- `anon`은 신규 사진 검사 함수 실행 불가, `authenticated`만 허용.

### SQL — 보고 댓글의 정확한 ID 반환
- 파일: `development/2026-11-15/JB_V1_3_보고댓글_정확한_댓글ID_반환.sql`
- 마이그레이션: `jb_v13_report_comment_exact_id_20261115`
- 기존 `jb_submit_report_core_v14`에 새 댓글을 INSERT한 후 트랜잭션 로컬 값 `jb.last_submitted_comment_id` 기록 한 줄 추가. **기존 함수의 인자/반환 request ID 및 보고·알림 처리 구조 유지.**
- 신규 `jb_submit_task_report_comment_id_v13(p_task_id uuid,p_body text,p_target_owner boolean)`가 기존 코어 호출 후 위 트랜잭션 로컬 값으로 **실제 댓글 UUID** 반환.
- 호출 권한: `authenticated` 허용, `anon` 차단. 기존 코어의 자격 검사는 그대로 유지.

### HTML — 개발 브랜치만 수정
- `development-test` 앱 HTML 마지막 수정 커밋: `38fb0f9ebac4adaa52af15d612a0ad167b50287a`.
- 댓글 사진 저장 경로를 `taskId/comments/commentId/fileUuid.jpg`로 분리, 기존 업무 사진은 `taskId/fileUuid.jpg` 유지.
- 보고 여부에 따라 신규 정확 ID 반환 RPC를 호출하며 기존 `body+created_at` 재조회 제거.
- 댓글 사진 일부만 실패하면 댓글은 보존하고 경고 표시.
- 각 **본인 댓글 아래**에 사진 추가/재시도 기능 제공. 중복 댓글 작성할 필요 없음.
- 댓글 사진 5장 제한 및 서버 권한 검사 유지.
- 개발사이트 전용 JB-DEV 오연결 방지 코드 그대로 유지.

## 확인된 자동 검사
- Dev HTML 4개 inline script 문법 검사 통과.
- 사진 경로/DB 삽입 mock 시험 3개 통과: 댓글 사진 `commentId` 연계, 일반 업무 사진 경로 보존, 총 5장 제한.
- SQL 경로 검사 5개 통과: 허용 경로 1개 및 구형/위조 확장자/경로 이탈/추가 경로 4개 거부.
- 개발 DB RLS 정책 3개 모두 생성, 신규 함수 2개 authenticated 호출 허용/anon 거부, 보고 코어에 exact ID 저장 및 wrapper 조회 코드 확인.
- DEV 사진/댓글 데이터 0건(테스트용 로그인 계정 0명): **실제 Auth/RLS/Storage 파일 업로드 및 모바일 테스트 미완료**.
- 운영 서비스 변경 없음.

## 다음 검증
1. 개발 Netlify 최신 커밋 `38fb0f9` Published 확인.
2. JB-DEV 개발 대표·관리자·직원 Auth 테스트 계정 생성 후 가상 직원 기록과 연결.
3. 서로 다른 부서의 작성자·담당자를 섞어 **본인 댓글 사진 성공 / 다른 사람 댓글 업로드 거부** 시험.
4. 일반 댓글, 상급자 확인 요청, 대표님 직접 보고 각 1회 사진 업로드 후 사진이 올바른 댓글 바로 아래 노출되는지 시험.
5. 갤럭시 카메라/사진 앨범 JPG, PNG, WEBP 및 원본 25MB 이하 자동 압축 시험. HEIC/HEIF 별도 검토.
6. 업무 사진과 댓글 사진 합계 5장, 6번째 업로드 차단, 실패 시 재첨부.
7. 댓글 삭제 시 기존 `ON DELETE SET NULL`로 첨부 사진이 업무 사진으로 재분류되는 문제 별도 개선 검토. 현재 사용자에게 동작 알림 필요.
8. 테스트 완료 후 명시적 운영 배포 요청이 있으면 **HTML + SQL 신규/보완 2종을 함께** 운영에 반영할 것. DEV 전용 Supabase URL 가드를 main에 복사하지 말 것.
