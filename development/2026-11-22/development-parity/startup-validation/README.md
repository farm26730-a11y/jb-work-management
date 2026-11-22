# JB-DEV 실행 HTML 시작 검증

기준 브랜치는 fix/jb-task-draft-clear-20261122, 기준 커밋은 7d7ba9a다.

- Chromium HTTPS에서 7d7ba9a 바로 전 버전의 빈 화면을 재현했다. 1583행의 독립된 `fu`가 ReferenceError를 일으켜 자동 초기화의 setup()까지 실행되지 않았다. 기준 커밋은 이미 이 찌꺼기를 제거했고, 저장소가 허용된 HTTPS에서는 연결 입력이 표시됐다.
- 기준 커밋에서 외부 Supabase 스크립트는 초기화보다 앞서 실행되어 응답이 느릴 때 표시를 지연시킬 수 있었다. Chromium 환경의 CDN 직접 요청은 ERR_CERT_AUTHORITY_INVALID였고, 상대 경로 아이콘은 CSP에 의해 차단됐다. 저장소 접근을 거부한 조건에서는 레거시 초기화도 SecurityError/연쇄 ReferenceError를 만들었다.
- 초기 상태 안내를 HTML에 두고 setup()에 외부 스크립트가 필요 없게 바꿨다. 연결 버튼에서만 Supabase JS를 요청하며, 실패 시 안내 후 재시도할 수 있다. 아이콘은 HTML에 포함했고, 브라우저 저장소 접근 예외도 처리했다. 연결 대상과 connect-src는 JB-DEV에 고정돼 있다.
- Chromium의 관리 정책이 file:// 탐색을 ERR_BLOCKED_BY_ADMINISTRATOR로 거부했다. 파일 URL의 화면은 이 환경에서 미검증이다. 동일 HTML을 로컬 HTTP 및 시험 HTTPS로 열어 실제 Chromium 화면과 동작을 검증했다.

| 검증 | 결과 |
|---|---|
| 초기 연결 화면 | PC 1280px HTTP 및 모바일 393px HTTPS 통과. CDN 요청 전에 표시됐고, localStorage 접근 차단 조건에서도 표시됐다. |
| 라이브러리 및 로그인 화면 | 변경 없는 HTML에 CDN에서 받은 실제 Supabase JS 바이트를 브라우저 요청 응답으로 제공하자 로그인 화면이 렌더링됐다. 실제 개발 계정으로 로그인하지는 않았다. |
| CDN 실패 | 메시지와 재시도 버튼 통과. 의도적 네트워크 실패 시험은 정상 경로 콘솔 검사와 별개다. |
| 업무 등록·초안 지우기 | 모의 인증과 직원·양식 데이터로 PC·모바일 통과. 홈 버튼으로 등록 화면에 진입한 뒤 제목·설명·첨부만 초기화하고 기존 반복 양식을 다시 적용했다. 정상 경로의 콘솔 오류 및 런타임 예외는 0건이었다. |
| 댓글 사진 | 프리뷰의 댓글·사진 로직과 앱 index.html은 이번 변경 범위에서 유지했다. 실서비스 업로드는 재검증하지 않았다. |

[연결 화면 PC](setup-pc.png) · [연결 화면 모바일](setup-mobile.png) · [업무 등록 PC](draft-pc.png) · [업무 등록 모바일](draft-mobile.png)

[JB-DEV 실행 HTML](../jb-dev-preview.html)을 내려받아 브라우저에서 연다. 파일 URL이 차단된 환경에서는 내려받은 폴더에서 `python3 -m http.server 8766 --bind 127.0.0.1`을 실행한 뒤 `http://127.0.0.1:8766/jb-dev-preview.html`을 연다. 연결 시 JB-DEV Publishable Key와 개발 계정을 사용한다. 운영 main·Supabase·Netlify에는 변경을 적용하지 않았다.
