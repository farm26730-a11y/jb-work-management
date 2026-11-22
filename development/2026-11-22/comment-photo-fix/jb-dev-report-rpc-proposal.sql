-- Review only. Apply to JB-DEV only after explicit approval.
BEGIN;
DO $guard$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_proc
  WHERE oid=pg_catalog.to_regprocedure('public.jb_submit_task_report_comment_id_v13(uuid,text,boolean)')
    AND NOT prosecdef
    AND pg_catalog.md5(prosrc)='af3e04a0683ea77b6c4e8332edaaf0e7'
 ) THEN
  RAISE EXCEPTION 'Unexpected JB-DEV RPC definition; review before applying';
 END IF;
END;
$guard$;
CREATE OR REPLACE FUNCTION public.jb_submit_task_report_comment_id_v13(p_task_id uuid, p_body text, p_target_owner boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_me public.jb_employees%ROWTYPE;
    v_task public.jb_tasks%ROWTYPE;
    v_note text;
    v_request_id uuid;
    v_comment_id uuid;
    v_existing boolean := false;
    v_owner_target boolean;
    v_receiver record;
    v_key text;
BEGIN
    SELECT *
    INTO v_me
    FROM public.jb_employees
    WHERE auth_user_id = auth.uid()
      AND active IS TRUE
    LIMIT 1;

    IF NOT FOUND
       OR v_me.app_role NOT IN ('staff', 'manager') THEN
        RAISE EXCEPTION '활성 직원 또는 부서장 계정이 필요합니다.';
    END IF;

    SELECT *
    INTO v_task
    FROM public.jb_tasks
    WHERE id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '업무를 찾을 수 없습니다.';
    END IF;

    IF v_task.assignee_id IS DISTINCT FROM v_me.id
       AND v_task.created_by IS DISTINCT FROM v_me.id THEN
        RAISE EXCEPTION '본인이 담당하거나 작성한 업무만 보고할 수 있습니다.';
    END IF;

    v_note := btrim(coalesce(p_body, ''));

    IF length(v_note) NOT BETWEEN 1 AND 2000 THEN
        RAISE EXCEPTION '보고 내용은 1~2000자로 입력하세요.';
    END IF;

    -- 부서장 보고는 대표님에게 전달
    v_owner_target :=
        p_target_owner IS TRUE;

    -- 동일 업무·직원 동시 보고 충돌 방지
    PERFORM pg_advisory_xact_lock(
        hashtext(p_task_id::text),
        hashtext(v_me.id::text)
    );

    -- 기존 미확인 요청을 우선 조회
    SELECT id
    INTO v_request_id
    FROM public.jb_task_report_requests
    WHERE task_id = p_task_id
      AND requester_id = v_me.id
      AND acknowledged_at IS NULL
    FOR UPDATE;

    v_existing := FOUND;

    -- 보고 댓글은 항상 새로 기록
    INSERT INTO public.jb_task_comments (
        task_id, author_id, body
    )
    VALUES (
        p_task_id, v_me.id, v_note
    )
    RETURNING id INTO v_comment_id;

    IF v_existing THEN
        -- 미확인 요청은 중복 생성하지 않음
        UPDATE public.jb_task_report_requests
        SET note = v_note,
            target_owner = v_owner_target
        WHERE id = v_request_id;

        -- 반복 보고에는 고유 알림 키 사용
        v_key := 'report:comment:' || v_comment_id::text;
    ELSE
        INSERT INTO public.jb_task_report_requests (
            task_id, requester_id, note, target_owner
        )
        VALUES (
            p_task_id, v_me.id, v_note, v_owner_target
        )
        RETURNING id INTO v_request_id;

        -- 기존 INSERT 트리거와 중복 발송 방지
        v_key := 'report:' || v_request_id::text;
    END IF;

    -- 보고 대상별 알림 대기열 등록
    FOR v_receiver IN
        SELECT id
        FROM public.jb_employees
        WHERE active IS TRUE
          AND id <> v_me.id
          AND (
              (
                  v_owner_target IS TRUE
                  AND app_role = 'owner'
              )
              OR (
                  v_owner_target IS FALSE
                  AND app_role = 'manager'

              )
          )
    LOOP
        PERFORM public.jb_queue_push_event(
            v_key,
            v_receiver.id,
            'report'
        );
    END LOOP;

    RETURN v_comment_id;
END;
$function$;
REVOKE ALL ON FUNCTION public.jb_submit_task_report_comment_id_v13(uuid,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.jb_submit_task_report_comment_id_v13(uuid,text,boolean) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
