-- ============================================================
-- এম.এস. পাবলিক স্কুল — Phase 2: Core Management
-- এই ফাইলটি supabase-setup.sql-এর পরে চালান। পুনরায় চালালে সমস্যা হবে না (idempotent)।
-- পুরনো ডেটা মুছে না। শুধু নতুন টেবিল, ফাংশন, নীতি (policy) ও স্টোরেজ নিয়ম যোগ/আপডেট হয়।
-- ============================================================

-- ------------------------------------------------------------
-- 1. ভূমিকা-ভিত্তিক সহায়ক ফাংশন
--    RLS নীতিতে এগুলো ব্যবহার হয়। security definer থাকায় নীতির ভেতরে আবার নীতি চেক হয় না।
-- ------------------------------------------------------------
create table if not exists user_roles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  role        text not null check (role in ('head','class_teacher','parent')),
  status      text not null default 'active' check (status in ('active','inactive')),
  login_id    text unique,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid
);

create or replace function is_head()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from user_roles
    where user_id = auth.uid() and role = 'head' and status = 'active'
  );
$$;

create or replace function is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('head','class_teacher') and status = 'active'
  );
$$;

-- ------------------------------------------------------------
-- 2. শ্রেণি ও বিষয়
-- ------------------------------------------------------------
create table if not exists classes (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,            -- যেমন: স্ট্যান্ডার্ড ওয়ান
  sort_order  int  not null default 0,
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid
);

create table if not exists subjects (
  id          uuid primary key default gen_random_uuid(),   -- স্থায়ী ID; ক্রম বদলালেও নম্বর ঠিক থাকবে
  class_id    uuid not null references classes(id) on delete restrict,
  name        text not null,
  max_marks   int  not null check (max_marks > 0),
  monthly     boolean not null default false,
  sort_order  int  not null default 0,
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists subjects_class_idx on subjects(class_id);

-- শ্রেণির নাম নির্দেশনা অনুযায়ী (ক্রমসহ)। আগে থাকলে কিছু করবে না।
insert into classes (name, sort_order) values
  ('নার্সারি', 1),
  ('স্ট্যান্ডার্ড', 2),
  ('স্ট্যান্ডার্ড ওয়ান', 3),
  ('স্ট্যান্ডার্ড টু', 4),
  ('স্ট্যান্ডার্ড থ্রি', 5),
  ('স্ট্যান্ডার্ড ফোর', 6),
  ('স্ট্যান্ডার্ড ফাইভ', 7)
on conflict (name) do nothing;
-- বিষয়গুলো পুরনো SUBJECTS তালিকা থেকে মাইগ্রেশন ধাপে যোগ হবে।

-- ------------------------------------------------------------
-- 3. শিক্ষক ও দায়িত্ব
-- ------------------------------------------------------------
create table if not exists teachers (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid unique references auth.users(id) on delete set null,
  name         text not null,
  designation  text,
  mobile       text,
  joined_on    date,
  subject      text,
  status       text not null default 'active' check (status in ('active','inactive')),
  signature_path text,                      -- Phase 5-এর জন্য রাখা
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid
);

create table if not exists class_teacher_assignments (
  id          uuid primary key default gen_random_uuid(),
  teacher_id  uuid not null references teachers(id) on delete cascade,
  class_id    uuid not null references classes(id) on delete cascade,
  from_date   date not null default current_date,
  to_date     date,                                  -- null = এখনও দায়িত্বে
  created_at  timestamptz not null default now(),
  created_by  uuid
);

create or replace function my_class_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select a.class_id
  from class_teacher_assignments a
  join teachers t on t.id = a.teacher_id
  where t.user_id = auth.uid()
    and (a.to_date is null or a.to_date >= current_date);
$$;

-- ------------------------------------------------------------
-- 4. শিক্ষার্থী, ফোন নম্বর ও অভিভাবক লিংক
-- ------------------------------------------------------------
create table if not exists students (
  id             uuid primary key default gen_random_uuid(),
  student_code   text unique,                 -- মানুষের পড়ার মতো আইডি (যেমন MSPS-2026-001)
  class_id       uuid not null references classes(id) on delete restrict,
  roll           int,
  name           text not null,
  dob            date,
  father         text,
  mother         text,
  address        text,
  admission_type text check (admission_type in ('new','old')),
  poor           boolean not null default false,
  family_code    text,
  religion       text,
  prev_school    text,
  whatsapp       boolean not null default false,
  status         text not null default 'active'
                 check (status in ('active','inactive','transferred','graduated')),
  photo_path     text,                        -- student-photos bucket-এর পথ
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid
);
create index if not exists students_class_idx on students(class_id);
create index if not exists students_family_idx on students(family_code);

create table if not exists student_phones (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references students(id) on delete cascade,
  phone       text not null check (phone ~ '^880[0-9]{10}$'),  -- 880 + ১০ অঙ্ক
  label       text,                              -- বাবা, মা, অন্য
  active      boolean not null default true,
  added_at    timestamptz not null default now(),
  removed_at  timestamptz,                       -- বাদ দেওয়া হলে তারিখ; মুছা হয় না
  created_by  uuid
);
create index if not exists student_phones_student_idx on student_phones(student_id);

create table if not exists parent_student_links (
  parent_user_id  uuid not null references auth.users(id) on delete cascade,
  student_id      uuid not null references students(id) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (parent_user_id, student_id)
);

create or replace function my_student_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select student_id from parent_student_links where parent_user_id = auth.uid();
$$;

create or replace function can_see_student(sid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select is_head()
      or exists (select 1 from students s where s.id = sid and s.class_id in (select my_class_ids()))
      or exists (select 1 from parent_student_links l where l.student_id = sid and l.parent_user_id = auth.uid());
$$;

-- ------------------------------------------------------------
-- 5. Audit Log — গুরুত্বপূর্ণ পরিবর্তনের রেকর্ড
-- ------------------------------------------------------------
create table if not exists audit_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid,
  action      text not null,
  table_name  text not null,
  row_id      text,
  before_data jsonb,
  after_data  jsonb,
  at          timestamptz not null default now()
);

create or replace function write_audit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_logs (actor_id, action, table_name, row_id, before_data, after_data)
  values (
    auth.uid(), tg_op, tg_table_name,
    coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id', ''),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

drop trigger if exists audit_students on students;
create trigger audit_students after insert or update or delete on students
  for each row execute function write_audit();

drop trigger if exists audit_student_phones on student_phones;
create trigger audit_student_phones after insert or update or delete on student_phones
  for each row execute function write_audit();

drop trigger if exists audit_teachers on teachers;
create trigger audit_teachers after insert or update or delete on teachers
  for each row execute function write_audit();

drop trigger if exists audit_subjects on subjects;
create trigger audit_subjects after insert or update or delete on subjects
  for each row execute function write_audit();

-- ------------------------------------------------------------
-- 6. RLS চালু
-- ------------------------------------------------------------
alter table user_roles               enable row level security;
alter table classes                  enable row level security;
alter table subjects                 enable row level security;
alter table teachers                 enable row level security;
alter table class_teacher_assignments enable row level security;
alter table students                 enable row level security;
alter table student_phones           enable row level security;
alter table parent_student_links     enable row level security;
alter table audit_logs               enable row level security;

-- user_roles: নিজের ভূমিকা দেখা যাবে; প্রধান শিক্ষক সব দেখবেন ও বদলাবেন
drop policy if exists "roles read own or head" on user_roles;
create policy "roles read own or head" on user_roles for select to authenticated
  using (user_id = auth.uid() or is_head());
drop policy if exists "roles head write" on user_roles;
create policy "roles head write" on user_roles for all to authenticated
  using (is_head()) with check (is_head());

-- classes / subjects: স্টাফ পড়বে, প্রধান শিক্ষক বদলাবেন
drop policy if exists "classes staff read" on classes;
create policy "classes staff read" on classes for select to authenticated using (is_staff());
drop policy if exists "classes head write" on classes;
create policy "classes head write" on classes for all to authenticated
  using (is_head()) with check (is_head());

drop policy if exists "subjects staff read" on subjects;
create policy "subjects staff read" on subjects for select to authenticated using (is_staff());
drop policy if exists "subjects head write" on subjects;
create policy "subjects head write" on subjects for all to authenticated
  using (is_head()) with check (is_head());

-- teachers: প্রধান শিক্ষক সব; শিক্ষক নিজের তথ্য দেখবেন
drop policy if exists "teachers read" on teachers;
create policy "teachers read" on teachers for select to authenticated
  using (is_head() or user_id = auth.uid());
drop policy if exists "teachers head write" on teachers;
create policy "teachers head write" on teachers for all to authenticated
  using (is_head()) with check (is_head());

-- class_teacher_assignments: প্রধান শিক্ষক সব; শিক্ষক নিজের দায়িত্ব দেখবেন
drop policy if exists "cta read" on class_teacher_assignments;
create policy "cta read" on class_teacher_assignments for select to authenticated
  using (is_head() or teacher_id in (select id from teachers where user_id = auth.uid()));
drop policy if exists "cta head write" on class_teacher_assignments;
create policy "cta head write" on class_teacher_assignments for all to authenticated
  using (is_head()) with check (is_head());

-- students: দেখবেন প্রধান শিক্ষক, নিজ শ্রেণির শিক্ষক, নিজ সন্তানের অভিভাবক। লেখার অনুমতি শুধু প্রধান শিক্ষকের
drop policy if exists "students read" on students;
create policy "students read" on students for select to authenticated
  using (can_see_student(id));
drop policy if exists "students head write" on students;
create policy "students head write" on students for all to authenticated
  using (is_head()) with check (is_head());

-- student_phones: একই নিয়ম
drop policy if exists "phones read" on student_phones;
create policy "phones read" on student_phones for select to authenticated
  using (can_see_student(student_id));
drop policy if exists "phones head write" on student_phones;
create policy "phones head write" on student_phones for all to authenticated
  using (is_head()) with check (is_head());

-- parent_student_links: প্রধান শিক্ষক সব; অভিভাবক নিজের লিংক দেখবেন
drop policy if exists "links read" on parent_student_links;
create policy "links read" on parent_student_links for select to authenticated
  using (is_head() or parent_user_id = auth.uid());
drop policy if exists "links head write" on parent_student_links;
create policy "links head write" on parent_student_links for all to authenticated
  using (is_head()) with check (is_head());

-- audit_logs: শুধু প্রধান শিক্ষক পড়বেন। লেখা হয় ট্রিগার দিয়ে
drop policy if exists "audit head read" on audit_logs;
create policy "audit head read" on audit_logs for select to authenticated using (is_head());

-- ------------------------------------------------------------
-- 7. আগের নীতি সংশোধন (গুরুত্বপূর্ণ)
--    আগে "to authenticated using (true)" ছিল। ব্যবহারকারী অ্যাকাউন্ট চালু হলে অভিভাবকও
--    authenticated হবেন, তাই এখন ওয়েবসাইট কনটেন্ট ও ব্যক্তি তালিকা লেখা শুধু প্রধান শিক্ষকের।
-- ------------------------------------------------------------
drop policy if exists "admin write settings" on site_settings;
create policy "admin write settings" on site_settings for all to authenticated
  using (is_head()) with check (is_head());

drop policy if exists "admin write notices" on notices;
create policy "admin write notices" on notices for all to authenticated
  using (is_head()) with check (is_head());

drop policy if exists "admin write events" on events;
create policy "admin write events" on events for all to authenticated
  using (is_head()) with check (is_head());

drop policy if exists "admin write gallery" on gallery;
create policy "admin write gallery" on gallery for all to authenticated
  using (is_head()) with check (is_head());

drop policy if exists "admin all people" on people;
create policy "admin all people" on people for all to authenticated
  using (is_head()) with check (is_head());

drop policy if exists "admin write condolences" on condolences;
create policy "admin write condolences" on condolences for all to authenticated
  using (is_head()) with check (is_head());

drop policy if exists "admin write assets" on storage.objects;
drop policy if exists "admin update assets" on storage.objects;
drop policy if exists "admin delete assets" on storage.objects;
drop policy if exists "head write assets" on storage.objects;
drop policy if exists "head update assets" on storage.objects;
drop policy if exists "head delete assets" on storage.objects;
create policy "head write assets" on storage.objects for insert to authenticated
  with check (bucket_id = 'public-assets' and is_head());
create policy "head update assets" on storage.objects for update to authenticated
  using (bucket_id = 'public-assets' and is_head());
create policy "head delete assets" on storage.objects for delete to authenticated
  using (bucket_id = 'public-assets' and is_head());

-- ------------------------------------------------------------
-- 8. শিক্ষার্থীর ছবি — Supabase Storage (student-photos, private)
--    পথ: students/<student_id>.jpg
--    দেখতে পারবেন: প্রধান শিক্ষক, নিজ শ্রেণির শিক্ষক, নিজ সন্তানের অভিভাবক।
--    লিখতে পারবেন: প্রধান শিক্ষক।
-- ------------------------------------------------------------
drop policy if exists "admin student photos" on storage.objects;

create or replace function photo_student_id(object_name text)
returns uuid language sql immutable as $$
  select nullif(regexp_replace(split_part(object_name, '/', 2), '\.jpg$', ''), '')::uuid;
$$;

drop policy if exists "photos read" on storage.objects;
create policy "photos read" on storage.objects for select to authenticated
  using (bucket_id = 'student-photos' and can_see_student(photo_student_id(name)));

drop policy if exists "photos head insert" on storage.objects;
create policy "photos head insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'student-photos' and is_head());

drop policy if exists "photos head update" on storage.objects;
create policy "photos head update" on storage.objects for update to authenticated
  using (bucket_id = 'student-photos' and is_head());

drop policy if exists "photos head delete" on storage.objects;
create policy "photos head delete" on storage.objects for delete to authenticated
  using (bucket_id = 'student-photos' and is_head());

-- ------------------------------------------------------------
-- 9. Supabase Auth সেটিংস (ড্যাশবোর্ডে করতে হবে, SQL দিয়ে নয়):
--    - Authentication → Providers → Email → "Confirm email" বন্ধ
--    - Authentication → Sign In / Up → "Allow new users to sign up" বন্ধ
--      (এটি বন্ধ না করলে যে কেউ নিজে অ্যাকাউন্ট খুলতে পারবে)
--    - Authentication → Password → Minimum length: 8
-- ------------------------------------------------------------
