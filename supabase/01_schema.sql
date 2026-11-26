-- Christmas Wish Tree — schema, RLS, seed
create table public.rooms (
  id serial primary key,
  name text not null unique,
  active boolean not null default true,
  sort_order int not null default 0
);

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  nickname text not null check (char_length(btrim(nickname)) between 1 and 30),
  nickname_key text generated always as (lower(regexp_replace(btrim(nickname), '\s+', ' ', 'g'))) stored,
  room_id int not null references public.rooms(id),
  pin_hash text not null,
  role text not null default 'user' check (role in ('user','admin')),
  active boolean not null default true,
  failed_count int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  unique (nickname_key, room_id)
);
create index profiles_room_idx on public.profiles(room_id);

-- one row per signed-in device (Supabase anonymous auth user -> profile)
create table public.sessions (
  auth_uid uuid primary key references auth.users(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index sessions_profile_idx on public.sessions(profile_id);

create table public.stockings (
  id int primary key,
  name text not null,
  image_url text,
  active boolean not null default true,
  sort_order int not null default 0
);

create table public.wishes (
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('gift','card','blessing')),
  message text not null check (char_length(message) between 1 and 150),
  category text check (char_length(category) <= 40),
  budget_range text check (char_length(budget_range) <= 40),
  stocking_id int not null references public.stockings(id),
  status text not null default 'OPEN' check (status in ('OPEN','CLAIMED','GIFTED','THANKED')),
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (type = 'gift' or (category is null and budget_range is null)),
  check (type <> 'blessing' or status = 'OPEN')
);
-- one gift-or-card wish + one blessing wish per person
create unique index wishes_one_per_kind on public.wishes(profile_id, (type = 'blessing'));
create index wishes_stocking_idx on public.wishes(stocking_id);
create index wishes_status_idx on public.wishes(status);

create table public.santa_claims (
  id bigint generated always as identity primary key,
  wish_id bigint not null references public.wishes(id) on delete cascade,
  santa_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','RELEASED','DELIVERED')),
  claimed_at timestamptz not null default now(),
  released_at timestamptz,
  delivered_at timestamptz,
  note text
);
-- second guard against two Santas: only one live claim per wish
create unique index santa_claims_one_live on public.santa_claims(wish_id) where status <> 'RELEASED';
create index santa_claims_santa_idx on public.santa_claims(santa_id);
create index santa_claims_wish_idx on public.santa_claims(wish_id);

create table public.blessings (
  id bigint generated always as identity primary key,
  wish_id bigint not null references public.wishes(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 150),
  is_anonymous boolean not null default false,
  created_at timestamptz not null default now(),
  unique (wish_id, sender_id)
);
create index blessings_sender_idx on public.blessings(sender_id);

create table public.thank_you (
  id bigint generated always as identity primary key,
  wish_id bigint not null unique references public.wishes(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 150),
  created_at timestamptz not null default now()
);
create index thank_you_sender_idx on public.thank_you(sender_id);
create index thank_you_recipient_idx on public.thank_you(recipient_id);

create table public.notifications (
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  title text not null,
  message text,
  wish_id bigint references public.wishes(id) on delete set null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_profile_idx on public.notifications(profile_id, read_at);
create index notifications_wish_idx on public.notifications(wish_id);

create table public.reports (
  id bigint generated always as identity primary key,
  wish_id bigint not null references public.wishes(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text check (char_length(reason) <= 200),
  status text not null default 'OPEN' check (status in ('OPEN','DISMISSED','ACTIONED')),
  created_at timestamptz not null default now(),
  unique (wish_id, reporter_id)
);
create index reports_reporter_idx on public.reports(reporter_id);

create table public.app_settings (
  key text primary key,
  value jsonb not null
);

-- ---------- helpers ----------
create function public.current_profile_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select s.profile_id from public.sessions s
  join public.profiles p on p.id = s.profile_id
  where s.auth_uid = auth.uid() and p.active
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.sessions s join public.profiles p on p.id = s.profile_id
    where s.auth_uid = auth.uid() and p.active and p.role = 'admin')
$$;

-- ---------- RLS ----------
alter table public.rooms enable row level security;
alter table public.profiles enable row level security;
alter table public.sessions enable row level security;
alter table public.stockings enable row level security;
alter table public.wishes enable row level security;
alter table public.santa_claims enable row level security;
alter table public.blessings enable row level security;
alter table public.thank_you enable row level security;
alter table public.notifications enable row level security;
alter table public.reports enable row level security;
alter table public.app_settings enable row level security;

-- public reference data (needed on the login screen)
create policy rooms_read on public.rooms for select to anon, authenticated
  using (active or (select public.is_admin()));
create policy stockings_read on public.stockings for select to anon, authenticated using (true);
create policy settings_read on public.app_settings for select to anon, authenticated using (true);

-- own notifications only
create policy notifications_own on public.notifications for select to authenticated
  using (profile_id = (select public.current_profile_id()) or (select public.is_admin()));

-- admins can read everything; users read wishes etc. only through functions
create policy profiles_admin on public.profiles for select to authenticated using ((select public.is_admin()));
create policy sessions_admin on public.sessions for select to authenticated using ((select public.is_admin()));
create policy wishes_admin on public.wishes for select to authenticated using ((select public.is_admin()));
create policy claims_admin on public.santa_claims for select to authenticated using ((select public.is_admin()));
create policy blessings_admin on public.blessings for select to authenticated using ((select public.is_admin()));
create policy thanks_admin on public.thank_you for select to authenticated using ((select public.is_admin()));
create policy reports_admin on public.reports for select to authenticated using ((select public.is_admin()));

-- the PIN hash is never readable through the API, even by admins
revoke select on public.profiles from anon, authenticated;
grant select (id, nickname, nickname_key, room_id, role, active, failed_count, locked_until, created_at)
  on public.profiles to authenticated;

-- ---------- seed ----------
insert into public.rooms (name, sort_order) values
  ('OPD16',1),('OPD30',2),('IPD',3),('DIS',4),('คลัง',5),('ผลิตยา',6),('ประกันสังคม',7);

insert into public.stockings (id, name, sort_order) values
  (1,'Red Christmas',1),(2,'Green Christmas',2),(3,'Blue Snow',3),(4,'Pink Ribbon',4),
  (5,'Snowman',5),(6,'Reindeer',6),(7,'Christmas Tree',7),(8,'Candy',8);

insert into public.app_settings (key, value) values
  ('wishes_open_until', '"2026-12-25"'),
  ('deliver_until', '"2026-12-31"'),
  ('reveal_santa_after_delivery', 'false'),
  ('max_active_missions', '2');
