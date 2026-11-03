-- Supabase SQL Editor-এ একবার চালান

create table if not exists site_settings (
  key text primary key,
  value text
);

create table if not exists notices (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  date date not null default current_date,
  created_at timestamptz default now()
);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  event_date text,
  created_at timestamptz default now()
);

create table if not exists gallery (
  id uuid primary key default gen_random_uuid(),
  url text not null,
  caption text,
  created_at timestamptz default now()
);

alter table site_settings enable row level security;
alter table notices enable row level security;
alter table events enable row level security;
alter table gallery enable row level security;

-- সবাই পড়তে পারবে
drop policy if exists "public read settings" on site_settings;
create policy "public read settings" on site_settings for select using (true);
drop policy if exists "public read notices" on notices;
create policy "public read notices" on notices for select using (true);
drop policy if exists "public read events" on events;
create policy "public read events" on events for select using (true);
drop policy if exists "public read gallery" on gallery;
create policy "public read gallery" on gallery for select using (true);

-- শুধু লগইন করা অ্যাডমিন লিখতে ও মুছতে পারবে
drop policy if exists "admin write settings" on site_settings;
create policy "admin write settings" on site_settings for all to authenticated using (true) with check (true);
drop policy if exists "admin write notices" on notices;
create policy "admin write notices" on notices for all to authenticated using (true) with check (true);
drop policy if exists "admin write events" on events;
create policy "admin write events" on events for all to authenticated using (true) with check (true);
drop policy if exists "admin write gallery" on gallery;
create policy "admin write gallery" on gallery for all to authenticated using (true) with check (true);

-- ছবি রাখার বাকেট (পাবলিক পড়া, শুধু অ্যাডমিন লেখা/মোছা)
insert into storage.buckets (id, name, public) values ('public-assets', 'public-assets', true)
on conflict (id) do nothing;

drop policy if exists "public read assets" on storage.objects;
create policy "public read assets" on storage.objects for select using (bucket_id = 'public-assets');
drop policy if exists "admin write assets" on storage.objects;
create policy "admin write assets" on storage.objects for insert to authenticated with check (bucket_id = 'public-assets');
drop policy if exists "admin update assets" on storage.objects;
create policy "admin update assets" on storage.objects for update to authenticated using (bucket_id = 'public-assets');
drop policy if exists "admin delete assets" on storage.objects;
create policy "admin delete assets" on storage.objects for delete to authenticated using (bucket_id = 'public-assets');

-- প্রাথমিক লেখা (অ্যাডমিন পরে বদলাতে পারবে)
insert into site_settings (key, value) values
  ('school_name', 'এম এস পাবলিক স্কুল'),
  ('top_tagline', 'এম এস ওয়েলফেয়ার অ্যাসোসিয়েশন কর্তৃক পরিচালিত'),
  ('hero_sub', 'শিলখালী (সাঁকুড়পাড়), পেকুয়া, কক্সবাজার'),
  ('hero_badge', 'স্থাপিত ২০০৮ খ্রি.'),
  ('slogan', 'পড় তোমার প্রভুর নামে যিনি সৃষ্টি করেছেন'),
  ('stat1_num', '২৫০+'), ('stat1_label', 'মোট শিক্ষার্থী'),
  ('stat2_num', '১০+'), ('stat2_label', 'অভিজ্ঞ শিক্ষক'),
  ('stat3_num', '৭'), ('stat3_label', 'শ্রেণি (নার্সারি–ফাইভ)'),
  ('stat4_num', '২০০৮'), ('stat4_label', 'স্থাপিত'),
  ('footer_address', 'সাঁকুড়পাড় স্টেশন, শিলখালী, পেকুয়া, কক্সবাজার')
on conflict (key) do nothing;

-- =====================================================
-- ব্যক্তিগত তালিকা (শিক্ষক ও শিক্ষার্থী): শুধু লগইন করা অ্যাডমিন দেখবে
-- =====================================================
create table if not exists people (
  id bigserial primary key,
  kind text not null check (kind in ('student','teacher')),
  name text not null,
  class_name text,
  dob date,
  phone text,
  father text,
  mother text,
  address text,
  consent boolean not null default false,
  created_at timestamptz not null default now()
);
alter table people enable row level security;
drop policy if exists "admin all people" on people;
create policy "admin all people" on people for all to authenticated using (true) with check (true);

-- জন্মদিনের ফাংশন: শুধু সম্মতি দেওয়া ব্যক্তির নাম, শ্রেণি, দিন ও মাস (সাল নয়, ফোন বা ঠিকানা নয়)
create or replace function today_birthdays()
returns table(name text, class_name text, kind text, bday_day int, bday_month int)
language sql stable security definer set search_path = public
as $$
  select p.name, p.class_name, p.kind, extract(day from p.dob)::int, extract(month from p.dob)::int
  from people p
  where p.consent = true
    and p.dob is not null
    and to_char(p.dob, 'MM-DD') = to_char((now() at time zone 'Asia/Dhaka')::date, 'MM-DD')
  order by p.kind, p.name;
$$;
grant execute on function today_birthdays() to anon, authenticated;

-- =====================================================
-- শিক্ষার্থীর ছবি: ব্যক্তিগত স্টোরেজ (পাবলিক নয়), শুধু লগইন করা অ্যাডমিন দেখবে
-- =====================================================
alter table people add column if not exists photo_path text;
insert into storage.buckets (id, name, public) values ('student-photos', 'student-photos', false)
on conflict (id) do nothing;
drop policy if exists "admin student photos" on storage.objects;
create policy "admin student photos" on storage.objects for all to authenticated
  using (bucket_id = 'student-photos') with check (bucket_id = 'student-photos');

-- =====================================================
-- জন্মদিন (নাম ও ছবি সহ) ও শোকবার্তা
-- =====================================================
alter table people add column if not exists public_photo_url text;

drop function if exists today_birthdays();
create or replace function today_birthdays()
returns table(name text, class_name text, kind text, bday_day int, bday_month int, photo_url text)
language sql stable security definer set search_path = public
as $$
  select p.name, p.class_name, p.kind, extract(day from p.dob)::int, extract(month from p.dob)::int, p.public_photo_url
  from people p
  where p.consent = true
    and p.dob is not null
    and to_char(p.dob, 'MM-DD') = to_char((now() at time zone 'Asia/Dhaka')::date, 'MM-DD')
  order by p.kind, p.name;
$$;
grant execute on function today_birthdays() to anon, authenticated;

create table if not exists condolences (
  id bigserial primary key,
  name text not null,
  relation text,
  message text not null,
  photo_url text,
  family_consent boolean not null default false,
  published_at timestamptz not null default now(),
  active_until timestamptz not null
);
alter table condolences enable row level security;
drop policy if exists "public read active condolences" on condolences;
create policy "public read active condolences" on condolences for select using (active_until > now());
drop policy if exists "admin write condolences" on condolences;
create policy "admin write condolences" on condolences for all to authenticated using (true) with check (true);
