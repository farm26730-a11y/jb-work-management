-- JB 업무관리 V1.3: 2026-11-13 운영 기록 초기화 FK 누락 보완
-- 적용 환경: 운영 Supabase bnonnvgtbukztfhaxgrr (2026-11-13 마이그레이션 성공)
-- 이 파일은 증빙 및 재설치용이며, 파일을 만드는 것만으로 데이터가 초기화되지 않습니다.
-- 실제 데이터 삭제는 대표 권한으로 RPC를 명시적으로 호출할 때만 발생합니다.
-- 21개 운영 기록 테이블 삭제 대상; 직원/부서/계정/템플릿/푸시/식사 설정 등 8개 보존.
-- 신규 jb_* 테이블이나 지정되지 않은 참조 외래키가 생기면 오류로 중단합니다.

CREATE OR REPLACE FUNCTION public.jb_owner_reset_operations_v11(p_phrase text, p_backup_confirmed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_owner uuid;
    v_reset regclass[] := ARRAY[
        'public.jb_announcement_reads'::regclass,
        'public.jb_announcements'::regclass,
        'public.jb_attendance'::regclass,
        'public.jb_attendance_notes'::regclass,
        'public.jb_events'::regclass,
        'public.jb_leave_change_requests'::regclass,
        'public.jb_leave_request_audit'::regclass,
        'public.jb_leave_requests'::regclass,
        'public.jb_notification_reads'::regclass,
        'public.jb_push_outbox'::regclass,
        'public.jb_task_comments'::regclass,
        'public.jb_task_history'::regclass,
        'public.jb_task_images'::regclass,
        'public.jb_task_report_requests'::regclass,
        'public.jb_tasks'::regclass,
        'public.jb_task_assignment_ack_v13'::regclass,
        'public.jb_task_comment_attention_v13'::regclass,
        'public.jb_meal_employee_v14'::regclass,
        'public.jb_meal_guest_v14'::regclass,
        'public.jb_meal_regular_orders_v15'::regclass,
        'public.jb_meal_rosters'::regclass
    ];
    v_preserve regclass[] := ARRAY[
        'public.jb_departments'::regclass,
        'public.jb_employees'::regclass,
        'public.jb_meal_regular_people_v15'::regclass,
        'public.jb_meal_settings'::regclass,
        'public.jb_name_login_attempts'::regclass,
        'public.jb_push_subscriptions'::regclass,
        'public.jb_staff_contact_numbers'::regclass,
        'public.jb_task_templates'::regclass
    ];
    v_unknown text;
    v_blockers text;
BEGIN
    SELECT e.id INTO v_owner
      FROM public.jb_employees AS e
     WHERE e.auth_user_id = (SELECT auth.uid())
       AND e.app_role = 'owner'
       AND e.active IS TRUE
     LIMIT 1;
    IF v_owner IS NULL THEN
        RAISE EXCEPTION '재직 중인 대표 계정만 운영 기록을 초기화할 수 있습니다'
            USING ERRCODE = '42501';
    END IF;

    IF p_phrase IS DISTINCT FROM '운영기록 전체 초기화'
       OR p_backup_confirmed IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION '백업 완료 확인 및 정확한 확인 문구가 필요합니다';
    END IF;

    PERFORM pg_advisory_xact_lock(31535, 11);

    -- 미래에 새 JB 업무관리 테이블이 추가되면 누락/무단삭제 없이 즉시 중단.
    SELECT string_agg(c.oid::regclass::text, ', ' ORDER BY c.relname)
      INTO v_unknown
      FROM pg_class AS c
      JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r','p')
       AND c.relname LIKE 'jb_%'
       AND NOT (c.oid::regclass = ANY(v_reset))
       AND NOT (c.oid::regclass = ANY(v_preserve));
    IF v_unknown IS NOT NULL THEN
        RAISE EXCEPTION '초기화 대상이 지정되지 않은 새 테이블이 있습니다: %', v_unknown;
    END IF;

    -- 다른 스키마 포함 모든 FK 확인. 새 참조가 생겨도 CASCADE 강제삭제 금지.
    SELECT string_agg(
             format('%s → %s (%s)', fk.conrelid::regclass::text, fk.confrelid::regclass::text, fk.conname),
             ', ' ORDER BY fk.conname
           )
      INTO v_blockers
      FROM pg_constraint AS fk
     WHERE fk.contype = 'f'
       AND fk.confrelid::regclass = ANY(v_reset)
       AND NOT (fk.conrelid::regclass = ANY(v_reset));
    IF v_blockers IS NOT NULL THEN
        RAISE EXCEPTION '운영 기록 초기화 차단 외래키: %', v_blockers;
    END IF;

    -- 모든 참조 자식 테이블을 명시하고 RESTRICT로 의도치 않은 삭제를 막습니다.
    TRUNCATE TABLE
        public.jb_announcement_reads,
        public.jb_announcements,
        public.jb_attendance,
        public.jb_attendance_notes,
        public.jb_events,
        public.jb_leave_change_requests,
        public.jb_leave_request_audit,
        public.jb_leave_requests,
        public.jb_notification_reads,
        public.jb_push_outbox,
        public.jb_task_comments,
        public.jb_task_history,
        public.jb_task_images,
        public.jb_task_report_requests,
        public.jb_tasks,
        public.jb_task_assignment_ack_v13,
        public.jb_task_comment_attention_v13,
        public.jb_meal_employee_v14,
        public.jb_meal_guest_v14,
        public.jb_meal_regular_orders_v15,
        public.jb_meal_rosters
    RESTRICT;

    RETURN jsonb_build_object(
        'success', true,
        'reset_table_count', cardinality(v_reset),
        'preserved_table_count', cardinality(v_preserve),
        'reset_at', now()
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.jb_owner_reset_operations_v11(text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_owner_reset_operations_v11(text,boolean) TO authenticated;
