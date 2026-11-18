-- =====================================================================
-- 오픈놀 커리어링크 · Supabase DB  v2.0  [10] 참여자 페이지 1단계
--  · 참여자 로그인 계정 ↔ 기존 관리번호 연결 (연결 코드 / 연결 요청 + 관리자 승인, 자동 확정 없음)
--  · 공통 취업 현황 조사: 제출 즉시 참여자 DB에 반영 (11/18 확정), 변경 이력은 경로 '설문 반영'
--  · 관리자: 계정 연결 · 취업 현황 조사 관리용 함수
--  · 참여자는 테이블을 직접 읽거나 쓰지 못하고, p_ 로 시작하는 함수로 본인 정보만 다룹니다.
--  · 09_add_enrollment.sql 다음에 실행합니다. 기존 데이터는 지우거나 바꾸지 않습니다. 여러 번 실행해도 안전합니다.
-- =====================================================================
begin;
-- ---------------------------------------------------------------------
-- 1. 기록자 열: 관리자가 아니면 비워 둠 (참여자 본인이 저장해도 오류가 나지 않도록)
-- ---------------------------------------------------------------------
create or replace function public._admin_uid() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select case when public.is_admin() then auth.uid() end
$$;

alter table public.participants    alter column created_by  set default public._admin_uid();
alter table public.participants    alter column updated_by  set default public._admin_uid();
alter table public.employments     alter column created_by  set default public._admin_uid();
alter table public.employments     alter column updated_by  set default public._admin_uid();
alter table public.status_history  alter column changed_by  set default public._admin_uid();
alter table public.change_log      alter column changed_by  set default public._admin_uid();
alter table public.consent_records alter column recorded_by set default public._admin_uid();
alter table public.audit_log       alter column admin_id    set default public._admin_uid();

create or replace function public.tg_touch() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := case when auth.uid() is null then new.updated_by else public._admin_uid() end;
  return new;
end $$;

-- 동의 기록 경로에 '참여자 본인' 추가
alter table public.consent_records drop constraint if exists consent_records_channel_check;
alter table public.consent_records add constraint consent_records_channel_check check (channel in ('admin','upload','survey','participant'));
-- 설문으로 등록되는 취업 기록
alter table public.employments drop constraint if exists employments_source_check;
alter table public.employments add constraint employments_source_check check (source in ('admin','upload','survey'));

-- ---------------------------------------------------------------------
-- 2. 새 테이블
-- ---------------------------------------------------------------------
create table if not exists public.participant_accounts (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  participant_id  bigint unique references public.participants(id),   -- 비어 있으면 아직 연결 전
  email           text,
  linked_via      text check (linked_via in ('code','request','admin')),
  linked_at       timestamptz,
  linked_by       uuid references public.admins(id),
  created_at      timestamptz not null default now(),
  last_seen_at    timestamptz
);

create table if not exists public.link_codes (
  id              bigint generated always as identity primary key,
  participant_id  bigint not null references public.participants(id),
  code_hash       text not null,            -- 코드 원문은 저장하지 않음 (sha256)
  expires_at      timestamptz not null,
  used_at         timestamptz,
  used_by         uuid,
  revoked_at      timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid references public.admins(id) default public._admin_uid()
);
create index if not exists link_codes_hash_idx on public.link_codes(code_hash) where used_at is null and revoked_at is null;
create index if not exists link_codes_p_idx on public.link_codes(participant_id, created_at desc);

create table if not exists public.link_requests (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  birth_date      date,
  phone           text,
  email           text,
  program_text    text,
  message         text,
  status          text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  participant_id  bigint references public.participants(id),
  reviewed_by     uuid references public.admins(id),
  reviewed_at     timestamptz,
  review_note     text,
  created_at      timestamptz not null default now()
);
create index if not exists link_requests_status_idx on public.link_requests(status, created_at desc);

create table if not exists public.link_attempts (
  id        bigint generated always as identity primary key,
  user_id   uuid not null,
  ok        boolean not null,
  at        timestamptz not null default now()
);
create index if not exists link_attempts_idx on public.link_attempts(user_id, at desc);

create table if not exists public.aftercare_profiles (
  participant_id     bigint primary key references public.participants(id),
  intent             text not null default 'unknown' check (intent in ('yes','no','later','unknown')),
  desired_supports   text[] not null default '{}',
  desired_jobs       text[] not null default '{}',
  interests          text[] not null default '{}',
  career_stage       text,
  source_response_id bigint,
  updated_at         timestamptz not null default now(),
  updated_by         uuid references public.admins(id) default public._admin_uid()
);

-- ---------------------------------------------------------------------
-- 3. 기존 조사 테이블에 열 추가 (기존 열·값은 그대로)
-- ---------------------------------------------------------------------
alter table public.survey_cycles add column if not exists code text;
alter table public.survey_cycles add column if not exists question_version text not null default 'v1';
create unique index if not exists survey_cycles_code_idx on public.survey_cycles(code) where code is not null;

alter table public.survey_responses add column if not exists user_id          uuid;
alter table public.survey_responses add column if not exists version_no       int not null default 1;
alter table public.survey_responses add column if not exists superseded_at    timestamptz;
alter table public.survey_responses add column if not exists apply_status     text check (apply_status in ('applied','pending_link'));
alter table public.survey_responses add column if not exists applied_at       timestamptz;
alter table public.survey_responses add column if not exists applied_diff     jsonb;
alter table public.survey_responses add column if not exists status_changed   boolean not null default false;
alter table public.survey_responses add column if not exists checked_at       timestamptz;
alter table public.survey_responses add column if not exists checked_by       uuid references public.admins(id);
alter table public.survey_responses add column if not exists aftercare_intent text;
alter table public.survey_responses add column if not exists desired_supports text[] not null default '{}';
alter table public.survey_responses add column if not exists desired_jobs     text[] not null default '{}';
alter table public.survey_responses add column if not exists career_stage     text;
create unique index if not exists survey_responses_current_idx on public.survey_responses(cycle_id, user_id) where superseded_at is null and user_id is not null;
create index if not exists survey_responses_cycle_idx on public.survey_responses(cycle_id, submitted_at desc);

-- 권한: 새 테이블은 관리자만 읽기, 쓰기는 함수로만
do $$
declare t text;
begin
  foreach t in array array['participant_accounts','link_codes','link_requests','link_attempts','aftercare_profiles'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists %1$s_read on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select to authenticated using (public.is_admin())', t);
  end loop;
end $$;
revoke select on public.link_codes, public.link_attempts from authenticated;   -- 코드 해시·시도 기록은 화면에서도 읽지 않음

-- ---------------------------------------------------------------------
-- 4. 참여자 공통 도우미 (내부용)
-- ---------------------------------------------------------------------
-- 로그인한 참여자 계정 행 (없으면 만듦). 관리자 계정은 참여자 기능을 쓸 수 없음
create or replace function public._p_account() returns public.participant_accounts
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts; uid uuid := auth.uid();
begin
  if uid is null then raise exception '로그인이 필요합니다.' using errcode = '42501'; end if;
  if public.is_admin() then raise exception '관리자 계정으로는 참여자 페이지를 이용할 수 없습니다.' using errcode = '42501'; end if;
  select * into a from participant_accounts where user_id = uid;
  if not found then
    insert into participant_accounts(user_id, email) values (uid, (select lower(email) from auth.users where id = uid)) returning * into a;
  end if;
  update participant_accounts set last_seen_at = now() where user_id = uid;
  return a;
end $$;

-- 연결된 참여자 번호 (삭제·통합된 참여자는 연결 없음으로 봄)
create or replace function public._p_pid(a public.participant_accounts) returns bigint
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id from participants p where p.id = a.participant_id and p.merged_into_id is null and p.deleted_at is null
$$;

create or replace function public._segment(s public.participant_status) returns text language sql immutable as $$
  select case when s in ('employed','startup') then 'worker' when s = 'unknown' then 'unknown' else 'seeker' end
$$;

create or replace function public._open_cycle() returns public.survey_cycles
language sql stable security definer set search_path = public, pg_temp as $$
  select * from survey_cycles where is_open and (opens_at is null or opens_at <= now()) and (closes_at is null or closes_at > now())
  order by coalesce(opens_at, created_at) desc, id desc limit 1
$$;

-- 연결 직후: 연결 대기 중에 낸 응답을 이 참여자에게 붙이고 반영
create or replace function public._attach_pending(uid uuid, pid bigint) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  update consent_records set participant_id = pid where participant_id is null and survey_response_id in (select id from survey_responses where user_id = uid);
  for r in select id from survey_responses where user_id = uid and participant_id is null order by submitted_at loop
    update survey_responses set participant_id = pid, matched_by = 'account' where id = r.id;
  end loop;
  -- 회차마다 가장 최근 응답만 반영 (이전 응답은 기록으로만 남음)
  for r in select id from survey_responses where user_id = uid and superseded_at is null and apply_status = 'pending_link' order by submitted_at loop
    perform public._apply_response(r.id); n := n + 1;
  end loop;
  return n;
end $$;

-- 응답을 참여자 DB에 반영 (승인 없이 즉시). 빈 값으로는 덮어쓰지 않음
create or replace function public._apply_response(rid bigint) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r survey_responses; p participants; c survey_cycles; a jsonb; diff jsonb := '[]'::jsonb; v text; cur employments;
        nst participant_status; knd text; changed boolean := false; contact_changed boolean := false; tag text;
begin
  select * into r from survey_responses where id = rid;
  if r.participant_id is null then return null; end if;
  select * into p from participants where id = r.participant_id;
  if not found or p.merged_into_id is not null or p.deleted_at is not null then return null; end if;
  select * into c from survey_cycles where id = r.cycle_id;
  a := r.answers; nst := r.reported_status; tag := coalesce(c.code, c.title, '') || ' 조사 응답';
  perform set_config('app.status_source', 'survey', true);
  perform set_config('app.status_reason', tag, true);
  perform set_config('app.ref_type', 'survey', true);
  perform set_config('app.ref_id', rid::text, true);

  -- 현재 상태
  if nst is distinct from p.current_status then
    diff := diff || jsonb_build_array(jsonb_build_object('field','current_status','old',p.current_status,'new',nst));
    changed := p.current_status <> 'unknown';
    update participants set current_status = nst where id = p.id;
  end if;
  -- 희망 직무 (첫 번째 선택)
  v := nullif(trim(coalesce(r.desired_jobs[1], '')), '');
  if v is not null and v is distinct from p.desired_job then
    diff := diff || jsonb_build_array(jsonb_build_object('field','desired_job','old',p.desired_job,'new',v));
    perform public._set_participant_field(p.id, 'desired_job', v);
  end if;
  -- 연락처 (형식이 맞을 때만)
  v := nullif(trim(coalesce(a->>'phone', '')), '');
  if v is not null and v ~ '^01[016789]-\d{3,4}-\d{4}$' and v is distinct from p.phone then
    diff := diff || jsonb_build_array(jsonb_build_object('field','phone','old',p.phone,'new',v));
    perform public._set_participant_field(p.id, 'phone', v); contact_changed := true;
  end if;
  v := lower(nullif(trim(coalesce(a->>'email', '')), ''));
  if v is not null and v ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and v is distinct from p.email then
    diff := diff || jsonb_build_array(jsonb_build_object('field','email','old',p.email,'new',v));
    perform public._set_participant_field(p.id, 'email', v); contact_changed := true;
  end if;
  -- 마케팅 수신 동의
  if r.consent ? 'marketing' and (r.consent->>'marketing')::boolean is distinct from p.consent_marketing then
    diff := diff || jsonb_build_array(jsonb_build_object('field','consent_marketing','old',p.consent_marketing,'new',(r.consent->>'marketing')::boolean));
    perform public._set_participant_field(p.id, 'consent_marketing', r.consent->>'marketing');
  end if;
  update consent_records set participant_id = p.id where survey_response_id = rid and participant_id is null;

  -- 직장: 추가만 (이전 직장은 종료일만 넣어 이력으로 남김)
  select * into cur from employments where participant_id = p.id and is_current order by start_date desc nulls last, id desc limit 1;
  v := nullif(trim(coalesce(r.company, '')), '');
  if nst in ('employed','startup') and v is not null then
    knd := case when nst = 'startup' then 'startup' else 'employed' end;
    if cur.id is null or lower(regexp_replace(coalesce(cur.company,''), '\s', '', 'g')) <> lower(regexp_replace(v, '\s', '', 'g')) then
      if cur.id is not null then
        update employments set is_current = false, end_date = coalesce(end_date, r.start_date, current_date) where id = cur.id;
        diff := diff || jsonb_build_array(jsonb_build_object('field','employment_end','old',cur.company,'new',null));
        insert into change_log(entity, entity_id, field, old_value, new_value, source, reason, ref_type, ref_id)
        values ('participants', p.id, 'employment_end', cur.company, null, 'survey', tag, 'survey', rid);
      end if;
      insert into employments(participant_id, kind, start_date, company, job_title, employment_type, work_region, is_current, source, survey_response_id)
      values (p.id, knd, r.start_date, v, nullif(trim(coalesce(r.job_title,'')), ''),
              case when r.employment_type in ('정규직','계약직','인턴','프리랜서','일용직','기타') then r.employment_type end,
              nullif(trim(coalesce(a->>'work_region','')), ''), true, 'survey', rid);
      diff := diff || jsonb_build_array(jsonb_build_object('field','employment','old',cur.company,'new',v));
      insert into change_log(entity, entity_id, field, old_value, new_value, source, reason, ref_type, ref_id)
      values ('participants', p.id, 'employment', null, concat_ws(' · ', v, nullif(trim(coalesce(r.job_title,'')), '')), 'survey', tag, 'survey', rid);
    else
      update employments set job_title = coalesce(job_title, nullif(trim(coalesce(r.job_title,'')), '')),
                             employment_type = coalesce(employment_type, case when r.employment_type in ('정규직','계약직','인턴','프리랜서','일용직','기타') then r.employment_type end),
                             start_date = coalesce(start_date, r.start_date)
       where id = cur.id;
    end if;
  elsif nst in ('seeking','education') and cur.id is not null then
    update employments set is_current = false, end_date = coalesce(end_date, current_date) where id = cur.id;
    diff := diff || jsonb_build_array(jsonb_build_object('field','employment_end','old',cur.company,'new',null));
    insert into change_log(entity, entity_id, field, old_value, new_value, source, reason, ref_type, ref_id)
    values ('participants', p.id, 'employment_end', cur.company, null, 'survey', tag, 'survey', rid);
  end if;

  -- 사후관리 정보
  insert into aftercare_profiles(participant_id, intent, desired_supports, desired_jobs, interests, career_stage, source_response_id, updated_at, updated_by)
  values (p.id, coalesce(r.aftercare_intent, 'unknown'), r.desired_supports, r.desired_jobs,
          coalesce(array(select jsonb_array_elements_text(coalesce(a->'interests', '[]'::jsonb))), '{}'), r.career_stage, rid, now(), null)
  on conflict (participant_id) do update set intent = excluded.intent, desired_supports = excluded.desired_supports, desired_jobs = excluded.desired_jobs,
    interests = excluded.interests, career_stage = excluded.career_stage, source_response_id = rid, updated_at = now(), updated_by = null;

  update participants set updated_at = now() where id = p.id;
  if contact_changed then perform public._detect_duplicates(p.id); end if;
  update survey_responses set apply_status = 'applied', review_status = 'applied', applied_at = now(), applied_diff = diff, status_changed = changed where id = rid;
  perform set_config('app.ref_type', '', true); perform set_config('app.ref_id', '', true);
  return diff;
end $$;

-- 생년월일 입력(YY-MM-DD, YYYY-MM-DD, 숫자 6·8자리) → date
create or replace function public._parse_birth(t text) returns date language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(t, ''), '\D', '', 'g'); y int;
begin
  if length(d) = 6 then y := substr(d, 1, 2)::int; d := (case when y > (extract(year from current_date)::int % 100) then '19' else '20' end) || d; end if;
  if length(d) <> 8 then return null; end if;
  return to_date(d, 'YYYYMMDD');
exception when others then return null;
end $$;

create or replace function public._norm_phone(t text) returns text language sql immutable as $$
  select case when d ~ '^01[016789]\d{7,8}$' then substr(d, 1, 3) || '-' || substr(d, 4, length(d) - 7) || '-' || right(d, 4) end
  from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') d) x
$$;

-- ---------------------------------------------------------------------
-- 5. 참여자 페이지용 함수 (로그인한 본인 정보만)
-- ---------------------------------------------------------------------
create or replace function public.p_me() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts; pid bigint; p participants; cy survey_cycles; mine survey_responses; req link_requests;
begin
  a := public._p_account(); pid := public._p_pid(a);
  cy := public._open_cycle();
  if cy.id is not null then
    select * into mine from survey_responses where user_id = a.user_id and cycle_id = cy.id and superseded_at is null;
  end if;
  select * into req from link_requests where user_id = a.user_id and status in ('pending','rejected') order by created_at desc limit 1;
  if pid is not null then select * into p from participants where id = pid; end if;
  return jsonb_build_object(
    'email', a.email,
    'linked', pid is not null,
    'request', case when req.id is null then null else jsonb_build_object('status', req.status, 'created_at', req.created_at, 'note', req.review_note) end,
    'participant', case when pid is null then null else jsonb_build_object(
        'code', p.code, 'name', p.name, 'current_status', p.current_status, 'segment', public._segment(p.current_status),
        'birth_date', p.birth_date, 'phone', p.phone, 'email', p.email, 'desired_job', p.desired_job, 'consent_marketing', p.consent_marketing,
        'enroll', coalesce((select jsonb_agg(jsonb_build_object('year', pr.year, 'name', pr.name, 'start_date', pr.start_date, 'end_date', pr.end_date) order by pr.year desc, pr.start_date desc nulls last)
                            from enrollments e join programs pr on pr.id = e.program_id where e.participant_id = pid), '[]'::jsonb),
        'job', (select jsonb_build_object('company', e.company, 'job_title', e.job_title, 'employment_type', e.employment_type, 'start_date', e.start_date, 'work_region', e.work_region, 'kind', e.kind)
                from employments e where e.participant_id = pid and e.is_current order by e.start_date desc nulls last, e.id desc limit 1),
        'aftercare', (select jsonb_build_object('intent', f.intent, 'desired_supports', f.desired_supports, 'desired_jobs', f.desired_jobs, 'career_stage', f.career_stage)
                      from aftercare_profiles f where f.participant_id = pid)) end,
    'cycle', case when cy.id is null then null else jsonb_build_object('id', cy.id, 'code', cy.code, 'title', cy.title, 'closes_at', cy.closes_at, 'policy_version', cy.policy_version,
        'submitted_at', mine.submitted_at, 'apply_status', mine.apply_status) end,
    'last_answers', (select jsonb_build_object('reported_status', s.reported_status, 'company', s.company, 'job_title', s.job_title, 'start_date', s.start_date,
                        'employment_type', s.employment_type, 'answers', s.answers, 'aftercare_intent', s.aftercare_intent, 'desired_supports', s.desired_supports,
                        'desired_jobs', s.desired_jobs, 'career_stage', s.career_stage, 'consent', s.consent, 'cycle_id', s.cycle_id)
                     from survey_responses s where s.user_id = a.user_id and s.superseded_at is null order by s.submitted_at desc limit 1));
end $$;

create or replace function public.p_link_with_code(code text, birth text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts; c link_codes; p participants; h text; fails int; b date;
begin
  a := public._p_account();
  if public._p_pid(a) is not null then raise exception '이미 연결된 계정입니다.'; end if;
  select count(*) into fails from link_attempts where user_id = a.user_id and not ok and at > now() - interval '1 hour';
  if fails >= 5 then raise exception '입력 실패가 많아 잠시 막았습니다. 1시간 뒤 다시 시도하거나 담당자에게 문의해 주세요.'; end if;
  h := encode(sha256(convert_to(upper(regexp_replace(coalesce(code, ''), '[^0-9A-Za-z]', '', 'g')), 'UTF8')), 'hex');
  b := public._parse_birth(birth);
  select * into c from link_codes where code_hash = h and used_at is null and revoked_at is null and expires_at > now() order by id desc limit 1;
  if c.id is not null then select * into p from participants where id = c.participant_id and merged_into_id is null and deleted_at is null; end if;
  if c.id is null or p.id is null or (p.birth_date is not null and (b is null or b <> p.birth_date)) then
    -- 실패 기록이 남도록 오류 대신 결과로 돌려줌 (오류를 내면 기록까지 취소됨)
    insert into link_attempts(user_id, ok) values (a.user_id, false);
    return jsonb_build_object('ok', false, 'message', '연결 코드 또는 생년월일이 맞지 않습니다. (1시간에 5번까지 시도할 수 있습니다)', 'left', greatest(0, 4 - fails));
  end if;
  if exists (select 1 from participant_accounts where participant_id = p.id and user_id <> a.user_id) then
    raise exception '이 정보는 이미 다른 계정에 연결되어 있습니다. 담당자에게 문의해 주세요.';
  end if;
  insert into link_attempts(user_id, ok) values (a.user_id, true);
  update participant_accounts set participant_id = p.id, linked_via = 'code', linked_at = now(), linked_by = null where user_id = a.user_id;
  update link_codes set used_at = now(), used_by = a.user_id where id = c.id;
  update link_codes set revoked_at = now() where participant_id = p.id and used_at is null and revoked_at is null;
  update link_requests set status = 'cancelled', review_note = '연결 코드로 연결됨' where user_id = a.user_id and status = 'pending';
  insert into change_log(entity, entity_id, field, old_value, new_value, source, reason) values ('participants', p.id, 'account', null, a.email, 'participant', '연결 코드로 계정 연결');
  insert into audit_log(action, target, detail) values ('account_link', 'participant:' || p.id, jsonb_build_object('via', 'code'));
  perform public._attach_pending(a.user_id, p.id);
  return public.p_me() || jsonb_build_object('ok', true);
end $$;

create or replace function public.p_request_link(req jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts; nm text := trim(coalesce(req->>'name', '')); b date := public._parse_birth(req->>'birth'); ph text := public._norm_phone(req->>'phone');
begin
  a := public._p_account();
  if public._p_pid(a) is not null then raise exception '이미 연결된 계정입니다.'; end if;
  if nm = '' then raise exception '이름을 입력해 주세요.'; end if;
  if b is null then raise exception '생년월일을 YY-MM-DD 형식으로 입력해 주세요. 예: 98-03-15'; end if;
  if ph is null then raise exception '휴대전화 번호를 확인해 주세요. 예: 010-1234-5678'; end if;
  if (select count(*) from link_requests where user_id = a.user_id and created_at > now() - interval '1 day') >= 3 then
    raise exception '연결 요청은 하루 3번까지 보낼 수 있습니다. 담당자 확인을 기다려 주세요.';
  end if;
  update link_requests set status = 'cancelled' where user_id = a.user_id and status = 'pending';
  insert into link_requests(user_id, name, birth_date, phone, email, program_text, message)
  values (a.user_id, nm, b, ph, a.email, left(nullif(trim(coalesce(req->>'program', '')), ''), 200), left(nullif(trim(coalesce(req->>'message', '')), ''), 300));
  return public.p_me();
end $$;

-- 조사 제출: 연결된 참여자는 즉시 DB 반영, 연결 전이면 '연결 대기'로 보관
create or replace function public.p_submit_survey(ans jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts; pid bigint; p participants; cy survey_cycles; st participant_status; prev survey_responses; rid bigint; diff jsonb;
        jobs text[]; sups text[]; et text; sd date; mk boolean; nm text;
begin
  a := public._p_account(); pid := public._p_pid(a);
  cy := public._open_cycle();
  if cy.id is null then raise exception '지금은 응답 기간이 아닙니다.'; end if;
  if coalesce((ans->'consent'->>'privacy')::boolean, false) is not true then raise exception '필수 개인정보 수집·이용에 동의해야 제출할 수 있습니다.'; end if;
  if coalesce(ans->>'status', '') not in ('seeking','employed','startup','education','other') then raise exception '현재 상태를 선택해 주세요.'; end if;
  st := (ans->>'status')::participant_status;
  jobs := array(select left(trim(x), 60) from jsonb_array_elements_text(coalesce(ans->'desired_jobs', '[]'::jsonb)) x where trim(x) <> '' limit 3);
  sups := array(select left(trim(x), 60) from jsonb_array_elements_text(coalesce(ans->'supports', '[]'::jsonb)) x where trim(x) <> '' limit 10);
  if cardinality(jobs) = 0 then raise exception '희망 직무를 하나 이상 선택해 주세요.'; end if;
  if cardinality(sups) = 0 then raise exception '필요한 지원 서비스를 하나 이상 선택해 주세요.'; end if;
  if coalesce(ans->>'career_stage', '') = '' then raise exception '현재 커리어 단계를 선택해 주세요.'; end if;
  if coalesce(ans->>'aftercare', '') not in ('yes','no','later') then raise exception '사후관리 참여 희망 여부를 선택해 주세요.'; end if;
  if coalesce(ans->>'phone', '') <> '' and public._norm_phone(ans->>'phone') is null then raise exception '휴대전화 번호 형식을 확인해 주세요. 예: 010-1234-5678'; end if;
  if coalesce(ans->>'email', '') <> '' and (ans->>'email') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception '이메일 형식을 확인해 주세요.'; end if;
  et := nullif(trim(coalesce(ans->>'employment_type', '')), '');
  begin sd := nullif(ans->>'start_date', '')::date; exception when others then sd := null; end;
  mk := (ans->'consent'->>'marketing')::boolean;
  if pid is not null then select * into p from participants where id = pid; nm := p.name;
  else nm := coalesce((select name from link_requests where user_id = a.user_id order by created_at desc limit 1), a.email); end if;

  select * into prev from survey_responses where user_id = a.user_id and cycle_id = cy.id and superseded_at is null for update;
  if prev.id is not null then update survey_responses set superseded_at = now() where id = prev.id; end if;
  insert into survey_responses(cycle_id, participant_id, matched_by, respondent_name, phone, email, reported_status, company, job_title, start_date, employment_type,
                               answers, consent, user_id, version_no, apply_status, review_status, aftercare_intent, desired_supports, desired_jobs, career_stage)
  values (cy.id, pid, case when pid is not null then 'account' end, nm, public._norm_phone(ans->>'phone'), lower(nullif(trim(coalesce(ans->>'email','')), '')), st,
          left(nullif(trim(coalesce(ans->>'company', '')), ''), 100), left(nullif(trim(coalesce(ans->>'job_title', '')), ''), 60), sd, et,
          jsonb_build_object('status_other', left(coalesce(ans->>'status_other', ''), 60), 'desired_jobs_other', left(coalesce(ans->>'desired_jobs_other', ''), 60),
                             'interests', coalesce(ans->'interests', '[]'::jsonb), 'interests_other', left(coalesce(ans->>'interests_other', ''), 60),
                             'supports_other', left(coalesce(ans->>'supports_other', ''), 60), 'work_region', left(coalesce(ans->>'work_region', ''), 40),
                             'phone', public._norm_phone(ans->>'phone'), 'email', lower(nullif(trim(coalesce(ans->>'email','')), '')),
                             'comment', left(coalesce(ans->>'comment', ''), 300), 'question_version', cy.question_version),
          jsonb_build_object('privacy', true, 'marketing', mk, 'policy_version', cy.policy_version, 'at', now()),
          a.user_id, coalesce(prev.version_no, 0) + 1, case when pid is null then 'pending_link' else 'applied' end, 'pending',
          ans->>'aftercare', sups, jobs, left(ans->>'career_stage', 40))
  returning id into rid;
  insert into consent_records(participant_id, survey_response_id, consent_type, agreed, policy_version, channel, recorded_by)
  values (pid, rid, 'privacy_collect', true, cy.policy_version, 'survey', null);
  if mk is not null then
    insert into consent_records(participant_id, survey_response_id, consent_type, agreed, policy_version, channel, recorded_by)
    values (pid, rid, 'marketing', mk, cy.policy_version, 'survey', null);
  end if;
  if pid is not null then diff := public._apply_response(rid); end if;
  return jsonb_build_object('response_id', rid, 'applied', pid is not null, 'diff', coalesce(diff, '[]'::jsonb), 'me', public.p_me());
end $$;

create or replace function public.p_my_responses() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts;
begin
  a := public._p_account();
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'cycle', coalesce(c.title, c.code), 'submitted_at', s.submitted_at, 'superseded', s.superseded_at is not null,
                    'reported_status', s.reported_status, 'company', s.company, 'job_title', s.job_title, 'desired_jobs', s.desired_jobs, 'supports', s.desired_supports,
                    'aftercare', s.aftercare_intent, 'apply_status', s.apply_status, 'marketing', s.consent->'marketing') order by s.submitted_at desc)
                   from survey_responses s left join survey_cycles c on c.id = s.cycle_id where s.user_id = a.user_id), '[]'::jsonb);
end $$;

create or replace function public.p_set_marketing(agree boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts; pid bigint;
begin
  a := public._p_account(); pid := public._p_pid(a);
  if pid is null then raise exception '계정 연결 후에 바꿀 수 있습니다.'; end if;
  if agree is null then raise exception '동의 여부를 선택해 주세요.'; end if;
  perform set_config('app.status_source', 'participant', true);
  perform set_config('app.status_reason', case when agree then '참여자 본인 마케팅 수신 동의' else '참여자 본인 마케팅 수신 철회' end, true);
  perform public._set_participant_field(pid, 'consent_marketing', agree::text);
  insert into consent_records(participant_id, consent_type, agreed, channel, recorded_by, withdrawn_at)
  values (pid, 'marketing', agree, 'participant', null, case when agree then null else now() end);
  update participants set updated_at = now() where id = pid;
  return public.p_me();
end $$;

-- ---------------------------------------------------------------------
-- 6. 관리자용 함수
-- ---------------------------------------------------------------------
-- 연결 코드 발급: 원문 코드는 이 응답에서만 보여 주고 저장하지 않음
create or replace function public.issue_link_codes(pids bigint[], days int default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid bigint; p participants; code text; abc text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea; i int; out jsonb := '[]'::jsonb; exp timestamptz;
begin
  perform public._require('editor');
  if cardinality(pids) > 1000 then raise exception '한 번에 1,000명까지 발급할 수 있습니다.'; end if;
  exp := now() + make_interval(days => least(greatest(coalesce(days, 30), 1), 90));
  foreach pid in array pids loop
    select * into p from participants where id = pid and merged_into_id is null and deleted_at is null;
    if not found then continue; end if;
    if exists (select 1 from participant_accounts where participant_id = pid) then
      out := out || jsonb_build_array(jsonb_build_object('participant_id', pid, 'code', p.code, 'name', p.name, 'skipped', '이미 계정 연결됨'));
      continue;
    end if;
    b := uuid_send(gen_random_uuid()); code := '';
    for i in 0..7 loop code := code || substr(abc, (get_byte(b, i) % 32) + 1, 1); end loop;
    update link_codes set revoked_at = now() where participant_id = pid and used_at is null and revoked_at is null;
    insert into link_codes(participant_id, code_hash, expires_at) values (pid, encode(sha256(convert_to(code, 'UTF8')), 'hex'), exp);
    out := out || jsonb_build_array(jsonb_build_object('participant_id', pid, 'code', p.code, 'name', p.name, 'phone', p.phone, 'email', p.email,
                                                     'link_code', substr(code, 1, 4) || '-' || substr(code, 5, 4), 'expires_at', exp));
  end loop;
  insert into audit_log(action, target, detail) values ('issue_link_codes', 'participants', jsonb_build_object('count', jsonb_array_length(out)));
  return out;
end $$;

-- 계정 연결 현황 목록. f: {q, link:'all'|'linked'|'code'|'none', year, biz, program}
create or replace function public.list_account_status(f jsonb default '{}'::jsonb, page int default 1, size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare q text := nullif(trim(coalesce(f->>'q','')), ''); lk text := coalesce(nullif(f->>'link',''), 'all');
        yr int := nullif(nullif(f->>'year','all'),'')::int; bz text := nullif(nullif(f->>'biz','all'),''); pg bigint := nullif(nullif(f->>'program','all'),'')::bigint; res jsonb;
begin
  perform public._require('admin');
  size := least(greatest(coalesce(size, 50), 1), 1000); page := greatest(coalesce(page, 1), 1);
  with base as (
    select p.id, p.code, p.name, p.phone, p.email, p.current_status, p.updated_at,
           a.email acc_email, a.linked_at, a.linked_via,
           (select jsonb_build_object('created_at', c.created_at, 'expires_at', c.expires_at, 'used_at', c.used_at, 'expired', c.expires_at <= now())
              from link_codes c where c.participant_id = p.id and c.revoked_at is null order by c.id desc limit 1) code_info
    from v_active_participants p left join participant_accounts a on a.participant_id = p.id
    where (q is null or p.name ilike '%' || q || '%' or p.code ilike '%' || q || '%' or p.phone_norm like '%' || regexp_replace(q, '\D', '', 'g') || '%' and length(regexp_replace(q, '\D', '', 'g')) >= 3)
      and (yr is null and bz is null and pg is null or exists (select 1 from enrollments e join programs pr on pr.id = e.program_id where e.participant_id = p.id
            and (yr is null or pr.year = yr) and (bz is null or coalesce(pr.biz_name, pr.name) = bz) and (pg is null or pr.id = pg)))
  ), filt as (
    select * from base where lk = 'all' or (lk = 'linked' and linked_at is not null)
      or (lk = 'code' and linked_at is null and code_info is not null and (code_info->>'used_at') is null and not (code_info->>'expired')::boolean)
      or (lk = 'none' and linked_at is null and (code_info is null or (code_info->>'expired')::boolean))
  )
  select jsonb_build_object('total', (select count(*) from filt),
    'counts', jsonb_build_object('all', (select count(*) from base), 'linked', (select count(*) from base where linked_at is not null),
                                 'code', (select count(*) from base where linked_at is null and code_info is not null and (code_info->>'used_at') is null and not (code_info->>'expired')::boolean)),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.code) from (select * from filt order by code limit size offset (page - 1) * size) x), '[]'::jsonb))
  into res;
  return res;
end $$;

create or replace function public.list_link_requests(st text default 'pending') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require('admin');
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
      'candidates', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'birth_date', p.birth_date, 'phone', p.phone, 'email', p.email,
                                 'score', (case when p.phone_norm = regexp_replace(coalesce(r.phone,''), '\D', '', 'g') and p.phone_norm <> '' then 50 else 0 end)
                                        + (case when p.name = r.name then 30 else 0 end) + (case when p.birth_date = r.birth_date then 20 else 0 end)
                                        + (case when p.email_norm = lower(coalesce(r.email,'')) and p.email_norm <> '' then 20 else 0 end),
                                 'linked', exists (select 1 from participant_accounts x where x.participant_id = p.id),
                                 'dup_n', (select count(*) from duplicate_candidates d where d.status = 'pending' and p.id in (d.participant_a, d.participant_b)),
                                 'programs', coalesce((select jsonb_agg(pr.year || ' ' || pr.name) from enrollments e join programs pr on pr.id = e.program_id where e.participant_id = p.id), '[]'::jsonb))
                               order by p.code)
                             from v_active_participants p
                             where (p.phone_norm <> '' and p.phone_norm = regexp_replace(coalesce(r.phone,''), '\D', '', 'g'))
                                or (p.name = r.name and p.birth_date = r.birth_date)
                                or (p.email_norm <> '' and p.email_norm = lower(coalesce(r.email,'')))), '[]'::jsonb),
      'reviewer', (select name from admins where id = r.reviewed_by)) order by r.created_at desc)
    from link_requests r where st = 'all' or r.status = st), '[]'::jsonb);
end $$;

-- 연결 요청 승인: pid를 주면 그 참여자에, create_new면 요청 정보로 새 참여자를 만들어 연결
create or replace function public.approve_link_request(req_id bigint, pid bigint default null, create_new boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r link_requests; a participant_accounts; target bigint := pid;
begin
  perform public._require('editor');
  select * into r from link_requests where id = req_id for update;
  if not found or r.status <> 'pending' then raise exception '처리할 연결 요청이 없습니다.'; end if;
  if exists (select 1 from admins where id = r.user_id) then raise exception '관리자 계정은 참여자로 연결할 수 없습니다.'; end if;
  select * into a from participant_accounts where user_id = r.user_id;
  if a.participant_id is not null and public._p_pid(a) is not null then raise exception '이 계정은 이미 다른 참여자에 연결되어 있습니다.'; end if;
  if create_new then
    perform set_config('app.status_reason', '계정 연결 요청으로 등록', true);
    perform set_config('app.status_source', 'admin', true);
    select id into target from public._insert_participant(jsonb_build_object('name', r.name, 'birth_date', r.birth_date, 'phone', r.phone, 'email', r.email));
    perform public._detect_duplicates(target);
  end if;
  if target is null or not exists (select 1 from participants where id = target and merged_into_id is null and deleted_at is null) then raise exception '연결할 참여자를 고르세요.'; end if;
  if exists (select 1 from participant_accounts where participant_id = target and user_id <> r.user_id) then raise exception '그 참여자는 이미 다른 계정에 연결되어 있습니다.'; end if;
  insert into participant_accounts(user_id, participant_id, email, linked_via, linked_at, linked_by)
  values (r.user_id, target, r.email, 'request', now(), auth.uid())
  on conflict (user_id) do update set participant_id = target, linked_via = 'request', linked_at = now(), linked_by = auth.uid();
  update link_requests set status = 'approved', participant_id = target, reviewed_by = auth.uid(), reviewed_at = now() where id = req_id;
  update link_codes set revoked_at = now() where participant_id = target and used_at is null and revoked_at is null;
  insert into change_log(entity, entity_id, field, old_value, new_value, source, reason) values ('participants', target, 'account', null, r.email, 'admin', '연결 요청 승인');
  insert into audit_log(action, target, detail) values ('account_link', 'participant:' || target, jsonb_build_object('via', 'request', 'request', req_id));
  perform public._attach_pending(r.user_id, target);
  return jsonb_build_object('participant_id', target, 'code', (select code from participants where id = target));
end $$;

create or replace function public.reject_link_request(req_id bigint, note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require('editor');
  update link_requests set status = 'rejected', review_note = left(nullif(trim(coalesce(note,'')), ''), 200), reviewed_by = auth.uid(), reviewed_at = now()
   where id = req_id and status = 'pending';
  if not found then raise exception '처리할 연결 요청이 없습니다.'; end if;
  insert into audit_log(action, target) values ('link_reject', 'link_request:' || req_id);
end $$;

create or replace function public.unlink_account(pid bigint, reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a participant_accounts;
begin
  perform public._require('editor');
  if coalesce(trim(reason), '') = '' then raise exception '해제 사유를 입력하세요.'; end if;
  select * into a from participant_accounts where participant_id = pid;
  if not found then raise exception '연결된 계정이 없습니다.'; end if;
  update participant_accounts set participant_id = null, linked_via = null, linked_at = null, linked_by = null where user_id = a.user_id;
  insert into change_log(entity, entity_id, field, old_value, new_value, source, reason) values ('participants', pid, 'account', a.email, null, 'admin', trim(reason));
  insert into audit_log(action, target, detail) values ('account_unlink', 'participant:' || pid, jsonb_build_object('reason', trim(reason)));
end $$;

-- 조사 회차
create or replace function public.list_survey_cycles() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require('admin');
  return coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object(
      'responses', (select count(*) from survey_responses s where s.cycle_id = c.id and s.superseded_at is null),
      'open_now', c.is_open and (c.opens_at is null or c.opens_at <= now()) and (c.closes_at is null or c.closes_at > now()))
    order by coalesce(c.opens_at, c.created_at) desc, c.id desc) from survey_cycles c), '[]'::jsonb);
end $$;

create or replace function public.save_survey_cycle(c jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare cid bigint := nullif(c->>'id','')::bigint; t text := trim(coalesce(c->>'title','')); cd text := nullif(trim(coalesce(c->>'code','')), '');
        op timestamptz := nullif(c->>'opens_at','')::timestamptz; cl timestamptz := nullif(c->>'closes_at','')::timestamptz; isop boolean := coalesce((c->>'is_open')::boolean, false);
begin
  perform public._require('editor');
  if t = '' then raise exception '회차 이름을 입력하세요.'; end if;
  if op is not null and cl is not null and cl <= op then raise exception '마감일이 시작일보다 늦어야 합니다.'; end if;
  if cid is null then
    insert into survey_cycles(title, code, opens_at, closes_at, is_open, policy_version) values (t, cd, op, cl, isop, coalesce(nullif(c->>'policy_version',''), 'v1')) returning id into cid;
  else
    update survey_cycles set title = t, code = cd, opens_at = op, closes_at = cl, is_open = isop, policy_version = coalesce(nullif(c->>'policy_version',''), policy_version) where id = cid;
  end if;
  if isop then update survey_cycles set is_open = false where id <> cid and is_open; end if;   -- 열린 회차는 하나만
  insert into audit_log(action, target, detail) values ('survey_cycle', 'survey_cycle:' || cid, jsonb_build_object('open', isop));
  return (select to_jsonb(x) from survey_cycles x where id = cid);
end $$;

-- 조사 응답 목록. f: {cycle, tab:'new'|'checked'|'pending_link'|'all', seg:'seeker'|'worker'|'all', status, changed:'1', q, old:'1'(이전 응답 포함)}
create or replace function public.list_survey_responses(f jsonb default '{}'::jsonb, page int default 1, size int default 30) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare cid bigint := nullif(nullif(f->>'cycle','all'),'')::bigint; tab text := coalesce(nullif(f->>'tab',''), 'all'); seg text := coalesce(nullif(f->>'seg',''), 'all');
        stt text := nullif(nullif(f->>'status','all'),''); q text := nullif(trim(coalesce(f->>'q','')), ''); ch boolean := coalesce(f->>'changed','') = '1';
        old boolean := coalesce(f->>'old','') = '1'; res jsonb;
begin
  perform public._require('admin');
  size := least(greatest(coalesce(size, 30), 1), 1000); page := greatest(coalesce(page, 1), 1);
  with base as (
    select s.*, p.code pcode, p.name pname, c.title cycle_title, c.code cycle_code
    from survey_responses s left join participants p on p.id = s.participant_id left join survey_cycles c on c.id = s.cycle_id
    where (cid is null or s.cycle_id = cid) and (old or s.superseded_at is null)
      and (q is null or s.respondent_name ilike '%' || q || '%' or p.code ilike '%' || q || '%' or p.name ilike '%' || q || '%')
  ), seg_f as (
    select * from base where (seg = 'all' or public._segment(reported_status) = seg) and (stt is null or reported_status::text = stt) and (not ch or status_changed)
  ), filt as (
    select * from seg_f where tab = 'all' or (tab = 'new' and apply_status = 'applied' and checked_at is null)
      or (tab = 'checked' and checked_at is not null) or (tab = 'pending_link' and apply_status = 'pending_link')
  )
  select jsonb_build_object('total', (select count(*) from filt),
    'tabs', jsonb_build_object('all', (select count(*) from seg_f), 'new', (select count(*) from seg_f where apply_status = 'applied' and checked_at is null),
                               'checked', (select count(*) from seg_f where checked_at is not null), 'pending_link', (select count(*) from seg_f where apply_status = 'pending_link')),
    'by_status', coalesce((select jsonb_object_agg(reported_status, n) from (select reported_status, count(*) n from base group by reported_status) t), '{}'::jsonb),
    'by_seg', coalesce((select jsonb_object_agg(sg, n) from (select public._segment(reported_status) sg, count(*) n from base group by 1) t), '{}'::jsonb),
    'changed_n', (select count(*) from base where status_changed),
    'linked_total', (select count(*) from participant_accounts a join v_active_participants p on p.id = a.participant_id),
    'active_total', (select count(*) from v_active_participants),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) - 'user_id' order by x.submitted_at desc) from (select * from filt order by submitted_at desc limit size offset (page - 1) * size) x), '[]'::jsonb))
  into res;
  return res;
end $$;

create or replace function public.mark_responses_checked(ids bigint[]) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  perform public._require('editor');
  update survey_responses set checked_at = now(), checked_by = auth.uid() where id = any(ids) and checked_at is null;
  get diagnostics n = row_count; return n;
end $$;

-- 대시보드·사이드바 숫자
create or replace function public.portal_counts() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require('admin');
  return jsonb_build_object(
    'link_pending', (select count(*) from link_requests where status = 'pending'),
    'survey_new', (select count(*) from survey_responses where superseded_at is null and apply_status = 'applied' and checked_at is null),
    'survey_pending_link', (select count(*) from survey_responses where superseded_at is null and apply_status = 'pending_link'),
    'linked', (select count(*) from participant_accounts a join v_active_participants p on p.id = a.participant_id));
end $$;

-- ---------------------------------------------------------------------
-- 7. 기존 함수 교체 (원문에 필요한 줄만 추가)
-- ---------------------------------------------------------------------
-- 변경 이력 트리거: 기록자는 관리자일 때만
create or replace function public.tg_change_log() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare k text; o jsonb := to_jsonb(old); n jsonb := to_jsonb(new);
        src text := coalesce(nullif(current_setting('app.status_source', true), ''), 'admin');
        rsn text := nullif(current_setting('app.status_reason', true), '');
        rt  text := nullif(current_setting('app.ref_type', true), '');
        ri  bigint := nullif(current_setting('app.ref_id', true), '')::bigint;
begin
  for k in select jsonb_object_keys(n) loop
    if k in ('updated_at','updated_by','created_at','created_by','phone_norm','email_norm','status_changed_at','current_status') then continue; end if;
    if (o -> k) is distinct from (n -> k) then
      insert into change_log(entity, entity_id, field, old_value, new_value, changed_by, source, reason, ref_type, ref_id)
      values (tg_table_name, new.id, k, o ->> k, n ->> k, public._admin_uid(), src, rsn, rt, ri);
    end if;
  end loop;
  return new;
end $$;

-- 변경 이력 트리거: 기록자는 관리자일 때만
create or replace function public.tg_status_history() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare rsn text := nullif(current_setting('app.status_reason', true), '');
        src text := coalesce(nullif(current_setting('app.status_source', true), ''), 'admin');
        rt  text := nullif(current_setting('app.ref_type', true), '');
        ri  bigint := nullif(current_setting('app.ref_id', true), '')::bigint;
begin
  if tg_op = 'INSERT' then
    insert into status_history(participant_id, from_status, to_status, reason, source, changed_by, ref_type, ref_id)
    values (new.id, null, new.current_status, coalesce(rsn, '최초 등록'), src, public._admin_uid(), rt, ri);
  elsif new.current_status is distinct from old.current_status then
    new.status_changed_at := now();
    insert into status_history(participant_id, from_status, to_status, reason, source, changed_by, ref_type, ref_id)
    values (new.id, old.current_status, new.current_status, rsn, src, public._admin_uid(), rt, ri);
  end if;
  return new;
end $$;

-- 참여자 상세: 계정 연결·연결 코드·사후관리 정보 추가
create or replace function public.participant_detail(pid bigint) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform public._require('admin');
  v := public.participant_view(pid);
  if v is null then raise exception '참여자를 찾을 수 없습니다.'; end if;
  insert into audit_log(action, target) values ('view_participant', 'participant:' || pid);
  return v || jsonb_build_object(
    'hist', coalesce((select jsonb_agg(to_jsonb(h) || jsonb_build_object('by', a.name) order by h.changed_at desc, h.id desc)
                      from status_history h left join admins a on a.id = h.changed_by where h.participant_id = pid), '[]'::jsonb),
    'chg',  coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('by', a.name) order by c.changed_at desc, c.id desc)
                      from change_log c left join admins a on a.id = c.changed_by where c.entity = 'participants' and c.entity_id = pid), '[]'::jsonb),
    'emps', coalesce((select jsonb_agg(to_jsonb(e) order by e.is_current desc, e.start_date desc nulls last) from employments e where e.participant_id = pid), '[]'::jsonb),
    'dup',  coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('other', public.participant_view(o.id)))
                      from duplicate_candidates d
                      join participants o on o.id = case when d.participant_a = pid then d.participant_b else d.participant_a end
                      where d.status = 'pending' and pid in (d.participant_a, d.participant_b) and o.merged_into_id is null and o.deleted_at is null), '[]'::jsonb),
    'consents', coalesce((select jsonb_agg(to_jsonb(c) order by c.recorded_at desc) from consent_records c where c.participant_id = pid), '[]'::jsonb),
    'surveys',  coalesce((select jsonb_agg(to_jsonb(s) - 'user_id' || jsonb_build_object('cycle_title', c.title, 'cycle_code', c.code) order by s.submitted_at desc)
                          from survey_responses s left join survey_cycles c on c.id = s.cycle_id where s.participant_id = pid), '[]'::jsonb),
    'account',  (select jsonb_build_object('email', a.email, 'linked_at', a.linked_at, 'linked_via', a.linked_via, 'last_seen_at', a.last_seen_at)
                 from participant_accounts a where a.participant_id = pid),
    'link_code', (select jsonb_build_object('created_at', c.created_at, 'expires_at', c.expires_at, 'used_at', c.used_at)
                  from link_codes c where c.participant_id = pid and c.revoked_at is null order by c.id desc limit 1),
    'aftercare', (select to_jsonb(f) from aftercare_profiles f where f.participant_id = pid));
end $$;

-- 중복 통합: 참여자 계정·연결 코드·사후관리 정보 처리 추가
create or replace function public.merge_participants(dup_id bigint, keep_id bigint) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d duplicate_candidates; lose_id bigint; keep participants; lose participants; k text; moved int := 0; dropped int := 0; x duplicate_candidates; other bigint;
begin
  perform public._require('owner');
  select * into d from duplicate_candidates where id = dup_id and status = 'pending' for update;
  if not found then raise exception '처리할 중복 의심이 없습니다.'; end if;
  if keep_id not in (d.participant_a, d.participant_b) then raise exception '남길 참여자가 올바르지 않습니다.'; end if;
  lose_id := case when d.participant_a = keep_id then d.participant_b else d.participant_a end;
  select * into keep from participants where id = keep_id; select * into lose from participants where id = lose_id;
  perform set_config('app.status_reason', lose.code || ' 통합', true);
  perform set_config('app.status_source', 'merge', true);

  delete from enrollments e where e.participant_id = lose_id and exists (select 1 from enrollments k2 where k2.participant_id = keep_id and k2.program_id = e.program_id);
  get diagnostics dropped = row_count;
  update enrollments set participant_id = keep_id where participant_id = lose_id; get diagnostics moved = row_count;
  if exists (select 1 from employments where participant_id = keep_id and is_current) then
    update employments set participant_id = keep_id, is_current = false where participant_id = lose_id;
  else update employments set participant_id = keep_id where participant_id = lose_id; end if;
  update status_history set participant_id = keep_id, reason = trim(coalesce(reason, '') || ' (' || lose.code || '에서 옮김)') where participant_id = lose_id;
  update change_log set entity_id = keep_id where entity = 'participants' and entity_id = lose_id;
  update consent_records set participant_id = keep_id where participant_id = lose_id;
  update survey_responses set participant_id = keep_id where participant_id = lose_id;

  foreach k in array public._participant_fields() loop
    if k in ('name','current_status') then continue; end if;
    if coalesce(to_jsonb(keep)->>k, '') = '' and coalesce(to_jsonb(lose)->>k, '') <> '' then perform public._set_participant_field(keep_id, k, to_jsonb(lose)->>k); end if;
  end loop;
  if keep.current_status = 'unknown' and lose.current_status <> 'unknown' then update participants set current_status = lose.current_status where id = keep_id; end if;
  -- 참여자 계정: 한쪽만 연결돼 있으면 남는 쪽으로 옮김, 둘 다면 통합하지 않음
  if exists (select 1 from participant_accounts where participant_id = lose_id) then
    if exists (select 1 from participant_accounts where participant_id = keep_id) then
      raise exception '두 참여자 모두 참여자 계정이 연결되어 있어 통합할 수 없습니다. 한쪽 연결을 먼저 해제하세요.';
    end if;
    update participant_accounts set participant_id = keep_id where participant_id = lose_id;
  end if;
  update link_codes set revoked_at = now() where participant_id = lose_id and used_at is null and revoked_at is null;
  insert into aftercare_profiles select keep_id, intent, desired_supports, desired_jobs, interests, career_stage, source_response_id, updated_at, updated_by
    from aftercare_profiles where participant_id = lose_id on conflict (participant_id) do nothing;
  update participants set merged_into_id = keep_id where id = lose_id;
  update duplicate_candidates set status = 'merged', resolved_by = auth.uid(), resolved_at = now() where id = dup_id;

  for x in select * from duplicate_candidates where status = 'pending' and lose_id in (participant_a, participant_b) loop
    other := case when x.participant_a = lose_id then x.participant_b else x.participant_a end;
    if other = keep_id or exists (select 1 from duplicate_candidates y where y.participant_a = least(other, keep_id) and y.participant_b = greatest(other, keep_id)) then
      update duplicate_candidates set status = 'merged', resolved_by = auth.uid(), resolved_at = now() where id = x.id;
    else update duplicate_candidates set participant_a = least(other, keep_id), participant_b = greatest(other, keep_id) where id = x.id; end if;
  end loop;
  insert into audit_log(action, target, detail) values ('merge', 'participant:' || keep_id, jsonb_build_object('merged', lose.code, 'moved', moved, 'dropped', dropped));
  return jsonb_build_object('keep', keep.code, 'lose', lose.code, 'moved', moved, 'dropped', dropped);
end $$;

-- 영구 삭제: 참여자 계정·연결 코드·사후관리 정보도 함께 지움
create or replace function public.purge_participant(pid bigint, confirm_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p participants; ids bigint[]; emp_ids bigint[];
begin
  perform public._require('owner');
  select * into p from participants where id = pid;
  if not found then raise exception '참여자를 찾을 수 없습니다.'; end if;
  if p.deleted_at is null then raise exception '먼저 삭제한 참여자만 영구 삭제할 수 있습니다.'; end if;
  if coalesce(trim(confirm_code), '') <> p.code then raise exception '확인용 관리번호가 맞지 않습니다.'; end if;
  -- 이 참여자로 통합되어 보관된 기록도 같은 사람이므로 함께 지움
  with recursive t(id) as (select pid union select c.id from participants c join t on c.merged_into_id = t.id)
  select array_agg(id) into ids from t;
  select coalesce(array_agg(id), '{}') into emp_ids from employments where participant_id = any(ids);
  delete from link_codes         where participant_id = any(ids);
  update link_requests set participant_id = null where participant_id = any(ids);
  delete from participant_accounts where participant_id = any(ids);
  delete from aftercare_profiles where participant_id = any(ids);
  delete from duplicate_candidates where participant_a = any(ids) or participant_b = any(ids);
  delete from consent_records    where participant_id = any(ids);
  delete from survey_responses   where participant_id = any(ids);
  delete from enrollments        where participant_id = any(ids);
  delete from change_log         where (entity = 'participants' and entity_id = any(ids)) or (entity = 'employments' and entity_id = any(emp_ids));
  delete from employments        where participant_id = any(ids);
  delete from status_history     where participant_id = any(ids);
  update upload_rows set normalized = null, dup_of = null, match_participant_id = null, participant_id = null
   where participant_id = any(ids) or match_participant_id = any(ids);
  delete from upload_undo where kind in ('participant','field','status') and ref_id = any(ids);
  update participants set merged_into_id = null where id = any(ids);
  delete from participants where id = any(ids);
  insert into audit_log(action, target, detail) values ('purge_participant', p.code, jsonb_build_object('records', cardinality(ids)));
  return jsonb_build_object('code', p.code, 'records', cardinality(ids));
end $$;

-- 관리자 등록: 참여자 계정은 관리자로 등록하지 않음
create or replace function public.register_admin(admin_email text, admin_name text, admin_role public.admin_role default 'admin') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid;
begin
  perform public._require('owner');
  select id into uid from auth.users where lower(email) = lower(trim(admin_email));
  if uid is null then raise exception 'Supabase > Authentication에서 이 이메일(%)로 사용자를 먼저 만들어 주세요.', admin_email; end if;
  if exists (select 1 from participant_accounts where user_id = uid) then raise exception '이 이메일은 참여자 계정으로 쓰이고 있어 관리자로 등록할 수 없습니다.'; end if;
  insert into admins(id, email, name, role, created_by) values (uid, lower(trim(admin_email)), admin_name, admin_role, auth.uid())
  on conflict (id) do update set name = excluded.name, role = excluded.role, is_active = true;
  insert into audit_log(action, target) values ('admin_register', admin_email);
  return (select to_jsonb(a) from admins a where id = uid);
end $$;

-- ---------------------------------------------------------------------
-- 8. 실행 권한: 익명 차단, 내부 함수는 화면에서 직접 실행 불가
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
revoke execute on function public._set_participant_field(bigint, text, text), public._record_consents(bigint, jsonb, text),
                           public._get_program(int, text, date, date, bigint), public._add_dup(bigint, bigint, text, int, bigint),
                           public._detect_duplicates(bigint), public._upload_apply(public.uploads, public.upload_rows), public._insert_participant(jsonb),
                           public._set_program_parts(bigint, jsonb), public._p_account(), public._p_pid(public.participant_accounts),
                           public._attach_pending(uuid, bigint), public._apply_response(bigint) from authenticated;
commit;

notify pgrst, 'reload schema';

-- 확인: 기존 데이터 건수 (실행 전과 같아야 합니다)
select (select count(*) from public.participants)   as "참여자",
       (select count(*) from public.enrollments)    as "참여 이력",
       (select count(*) from public.employments)    as "취업 기록",
       (select count(*) from public.change_log)     as "변경 이력",
       (select count(*) from public.participant_accounts) as "참여자 계정";
