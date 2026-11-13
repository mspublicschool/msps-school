-- ============================================================
-- Smart ID Card: Phase A (ডেটাবেস ও নিরাপত্তা)
-- চালানোর ক্রম: setup → phase2 → documents → finance → scholarship → teacher-profile → এই ফাইল
-- idempotent: একাধিকবার চালালেও সমস্যা হবে না।
--
-- নীতি:
--  * QR কোডে কোনো ব্যক্তিগত তথ্য থাকবে না, শুধু একটি এলোমেলো card_token।
--  * জনসাধারণ যাচাই করতে পারবে শুধু বৈধ/অবৈধ অবস্থা (নাম, ফোন, রক্তের গ্রুপ দেখাবে না)।
--  * কার্ড তৈরি, বাতিল, পুনঃইস্যু শুধু প্রধান শিক্ষক করবেন; প্রতিটি কাজ id_card_logs-এ লেখা থাকবে।
-- ============================================================

-- ---------- শিক্ষার্থী: আইডি কার্ডের জন্য নতুন কলাম ----------
alter table students add column if not exists mobile text;                 -- শিক্ষার্থী/অভিভাবকের মোবাইল (কার্ডে দেখানো)
alter table students add column if not exists blood_group text
  check (blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-','জানা নেই'));
alter table students add column if not exists card_no text unique;        -- যেমন MS-2026-3-001
alter table students add column if not exists card_token uuid unique default gen_random_uuid();
alter table students add column if not exists card_status text not null default 'draft'
  check (card_status in ('draft','active','revoked'));
alter table students add column if not exists card_issued_on date;
alter table students add column if not exists card_valid_until date;

-- ---------- শিক্ষক: আইডি কার্ডের জন্য নতুন কলাম ----------
-- (blood_group ও teacher_code supabase-teacher-profile.sql-এ আছে; এখানে নিরাপদভাবে নিশ্চিত করা হলো)
alter table teachers add column if not exists blood_group text
  check (blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-','জানা নেই'));
alter table teachers add column if not exists teacher_code text unique;    -- যেমন MS-T-2026-11-001
alter table teachers add column if not exists card_token uuid unique default gen_random_uuid();
alter table teachers add column if not exists card_status text not null default 'draft'
  check (card_status in ('draft','active','revoked'));
alter table teachers add column if not exists card_issued_on date;
alter table teachers add column if not exists card_valid_until date;

create index if not exists students_card_status_idx on students(card_status);
create index if not exists teachers_card_status_idx on teachers(card_status);

-- ---------- কার্ড কার্যক্রমের লগ (কে, কখন, কী করল) ----------
create table if not exists id_card_logs (
  id          bigint generated always as identity primary key,
  person_kind text not null check (person_kind in ('student','teacher')),
  person_id   uuid not null,
  action      text not null check (action in ('issue','reissue','revoke','reactivate','print','export')),
  note        text,
  done_by     uuid default auth.uid(),
  done_at     timestamptz not null default now()
);
create index if not exists id_card_logs_person_idx on id_card_logs(person_kind, person_id);

alter table id_card_logs enable row level security;

drop policy if exists "id_card_logs head read" on id_card_logs;
create policy "id_card_logs head read" on id_card_logs
  for select using (is_head());

drop policy if exists "id_card_logs head insert" on id_card_logs;
create policy "id_card_logs head insert" on id_card_logs
  for insert with check (is_head() and done_by = auth.uid());

-- লগ কেউ বদলাতে বা মুছতে পারবে না (update/delete policy নেই)
revoke update, delete on id_card_logs from anon, authenticated;
grant select, insert on id_card_logs to authenticated;
grant usage on sequence id_card_logs_id_seq to authenticated;

-- ---------- জনসাধারণের যাচাই (QR স্ক্যান) ----------
-- শুধু বৈধতার অবস্থা ফেরত দেয়। কোনো নাম, ফোন, ঠিকানা বা রক্তের গ্রুপ নয়।
create or replace function verify_id_card(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  r record;
  v_state text;
begin
  if p_token is null then
    return json_build_object('result', 'invalid');
  end if;

  select 'student' as kind, card_status, card_valid_until into r
    from students where card_token = p_token;
  if not found then
    select 'teacher' as kind, card_status, card_valid_until into r
      from teachers where card_token = p_token;
  end if;
  if not found then
    return json_build_object('result', 'invalid');
  end if;

  if r.card_status = 'revoked' then
    v_state := 'revoked';
  elsif r.card_status <> 'active' then
    v_state := 'invalid';
  elsif r.card_valid_until is not null and r.card_valid_until < current_date then
    v_state := 'expired';
  else
    v_state := 'valid';
  end if;

  return json_build_object(
    'result', v_state,
    'kind', r.kind,
    'valid_until', r.card_valid_until,
    'school', 'এম এস পাবলিক স্কুল'
  );
end;
$$;

revoke all on function verify_id_card(uuid) from public;
grant execute on function verify_id_card(uuid) to anon, authenticated;

-- ---------- প্রধান শিক্ষক: কার্ড স্ট্যাটাস বদলানো ----------
-- ব্যবহার: select set_card_status('student', '<id>', 'active', '2026-12-31', 'প্রথম ইস্যু');
create or replace function set_card_status(
  p_kind text, p_id uuid, p_status text, p_valid_until date, p_note text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_head() then
    raise exception 'শুধু প্রধান শিক্ষক কার্ড বদলাতে পারবেন';
  end if;
  if p_kind not in ('student','teacher') then
    raise exception 'ভুল ধরন: %', p_kind;
  end if;
  if p_status not in ('draft','active','revoked') then
    raise exception 'ভুল স্ট্যাটাস: %', p_status;
  end if;

  if p_kind = 'student' then
    update students set
      card_status = p_status,
      card_valid_until = coalesce(p_valid_until, card_valid_until),
      card_issued_on = case when p_status = 'active' and card_issued_on is null then current_date else card_issued_on end,
      updated_at = now()
    where id = p_id;
  else
    update teachers set
      card_status = p_status,
      card_valid_until = coalesce(p_valid_until, card_valid_until),
      card_issued_on = case when p_status = 'active' and card_issued_on is null then current_date else card_issued_on end,
      updated_at = now()
    where id = p_id;
  end if;

  if not found then
    raise exception 'ব্যক্তি পাওয়া যায়নি';
  end if;

  insert into id_card_logs(person_kind, person_id, action, note, done_by)
  values (
    p_kind, p_id,
    case p_status when 'revoked' then 'revoke' when 'active' then 'issue' else 'reissue' end,
    p_note, auth.uid()
  );
end;
$$;

revoke all on function set_card_status(text, uuid, text, date, text) from public;
grant execute on function set_card_status(text, uuid, text, date, text) to authenticated;

-- ---------- প্রিন্ট/এক্সপোর্ট লগ (প্রধান শিক্ষক) ----------
create or replace function log_card_print(p_kind text, p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_head() then
    raise exception 'শুধু প্রধান শিক্ষক প্রিন্ট লগ লিখতে পারবেন';
  end if;
  insert into id_card_logs(person_kind, person_id, action, done_by)
  select p_kind, unnest(p_ids), 'print', auth.uid();
end;
$$;

revoke all on function log_card_print(text, uuid[]) from public;
grant execute on function log_card_print(text, uuid[]) to authenticated;
