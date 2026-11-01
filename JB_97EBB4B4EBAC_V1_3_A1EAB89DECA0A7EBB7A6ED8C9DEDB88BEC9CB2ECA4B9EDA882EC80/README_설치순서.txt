JB 업무관리 V1.3 푸시 발송 서버 준비본

1. 기존 Netlify 사이트의 ZIP 수동 드롭 배포만으로는 Node 의존성 설치 및 Functions 빌드가 보장되지 않습니다. Git 저장소를 연결해 이 폴더 전체를 배포하세요.
2. Netlify Site configuration > Environment variables 설정:
   SUPABASE_URL = 프로젝트 URL
   SUPABASE_SERVICE_ROLE_KEY = service_role (서버 환경변수에만 저장, HTML/깃 저장소 공개 금지)
   VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY = 한 쌍의 web-push VAPID 키
   VAPID_SUBJECT = mailto:회사 관리 이메일
3. Supabase에서 푸시 대기열 SQL 설치 여부와 Storage의 jb_push_subscriptions 테이블 정책 확인.
4. Git 연결 배포 후 Netlify Functions 목록에서 push-config, push-dispatch (Scheduled) 존재 확인.
5. 앱 알림센터에서 '이 휴대폰 알림 등록' 클릭, 갤럭시 권한 허용.
6. 업무 지시를 실제 생성하고 outbox, Netlify Functions 로그, 기기 수신 확인.
7. 서버 예약 실행은 1분 간격이므로 즉시 발송 보장 아님.

주의: 이 패키지는 Netlify 계정·Supabase에 자동 배포하지 않습니다. 공개 VAPID 키는 서비스에서 불러오며, 서버 비밀키는 브라우저에서 절대 사용하지 않습니다. 현재 대기열 트리거는 업무 신규 등록과 휴무 신규·승인·변경에 초점을 두고 있습니다. 댓글/대표 직접 보고/공지/긴급 보고는 추가 이벤트 트리거가 필요합니다.
로그인 유지: 기존 Supabase localStorage 자동 토큰 갱신을 유지하고 직원 조회 중 일시적 연결 실패에 signOut 하지 않도록 수정. 영구 로그인 보장 불가.
