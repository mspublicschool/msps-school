-- ============================================================
-- শিক্ষকের প্রোফাইল: সাধারণ তথ্য (teachers) ও গোপনীয় তথ্য (teacher_private)
-- চালানোর ক্রম: setup → phase2 → documents → finance → scholarship → এই ফাইল
-- idempotent: একাধিকবার চালালেও সমস্যা হবে না।
-- ============================================================

-- সাধারণ তথ্য (আইডি কার্ড ও স্টাফ তালিকায় দেখানো যাবে)
alter table teachers add column if not exists employment_type text
  check (employment_type in ('স্থায়ী','খণ্ডকালীন'));
alter table teachers add column if not exists appointed_on date;     -- নিয়োগপত্রের তারিখ
alter table teachers add column if not exists photo_url text;
alter table teachers add column if not exists blood_group text
  check (blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-','জানা নেই'));
alter table teachers add column if not exists teacher_code text unique;  -- যেমন MS-T-2026-11-001

-- গোপনীয় তথ্য: শুধু প্রধান শিক্ষক এবং শিক্ষক নিজে (নিজেরটি) দেখবেন
create table if not exists teacher_private (
  teacher_id          uuid primary key references teachers(id) on delete cascade,
  date_of_birth       date,
  gender              text check (gender in ('পুরুষ','নারী','অন্যান্য')),
  nid                 text,                 -- জাতীয় পরিচয়পত্র
  present_address     text,
  permanent_address   text,
  emergency_name      text,
  emergency_relation  text,
  emergency_mobile    text,
  qualification       text,                 -- শিক্ষাগত যোগ্যতা
  training            text,                 -- প্রশিক্ষণ
  updated_at          timestamptz not null default now()
);

alter table teacher_private enable row level security;

drop policy if exists "head manage teacher private" on teacher_private;
create policy "head manage teacher private" on teacher_private
  for all to authenticated using (is_head()) with check (is_head());

drop policy if exists "teacher read own private" on teacher_private;
create policy "teacher read own private" on teacher_private
  for select to authenticated using (
    exists (select 1 from teachers t where t.id = teacher_private.teacher_id and t.user_id = auth.uid())
  );

grant select, insert, update, delete on teacher_private to authenticated;
