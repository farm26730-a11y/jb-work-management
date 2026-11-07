-- [조회용] 휴무 신청/승인 푸시 알림 라우팅 검증
-- 데이터·함수·정책·트리거 변경 없음
-- 실제 관리자 소속 부서 확인 및 권한 점검의 근거 자료

-- 1. 휴무 및 변경·취소 관련 트리거가 어떤 함수를 호출하는지
SELECT event_object_table AS table_name,
       trigger_name, action_timing, event_manipulation, action_statement
FROM information_schema.triggers
WHERE trigger_schema='public'
  AND event_object_table IN ('jb_leave_requests','jb_leave_change_requests')
ORDER BY event_object_table, trigger_name, event_manipulation;

-- 2. 관련 푸시 함수의 현재 정의
SELECT p.proname AS function_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       pg_get_functiondef(p.oid) AS function_definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND (p.proname LIKE '%push%leave%'
       OR p.proname IN ('jb_queue_push_event','jb_review_leave_companywide',
                       'jb_leave_visible_requests','jb_leave_change_visible'))
ORDER BY p.proname;

-- 3. 실제 알림 큐의 이벤트 종류와 최근 발송 오류 집계 (민감한 메시지 본문 미조회)
SELECT event_type,
       count(*) AS total_count,
       count(*) FILTER (WHERE sent_at IS NULL) AS pending_count,
       count(*) FILTER (WHERE last_error IS NOT NULL) AS error_count
FROM public.jb_push_outbox
GROUP BY event_type
ORDER BY event_type;
