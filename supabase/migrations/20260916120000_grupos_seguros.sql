-- =====================================================================
-- MIGRACIÓN: grupos de trabajo práctico — seguridad y lógica completa
-- Proyecto: trabajo-practico-grupos (bgtlfjksjjdrdcfeyutv)
--
-- QUÉ HACE (resumen; detalle en LEEME.md):
--   * NO borra tablas ni datos de estudiantes/grupos/membresías.
--   * Normaliza el formato de cédulas, teléfonos y nombres existentes
--     (quita puntos/espacios/guiones). Si eso generara duplicados, ABORTA.
--   * Agrega students.pin_hash (PIN de 4–6 dígitos, guardado con bcrypt).
--   * Crea: app_settings, student_sessions, admin_sessions, auth_events.
--   * Agrega triggers: tope de 12 integrantes (con bloqueo de fila),
--     borrado de grupos que quedan vacíos, normalización/validación.
--   * Crea funciones RPC app_* que usa la Edge Function.
--   * Activa RLS en todas las tablas, ELIMINA las políticas existentes de
--     esas tablas (las lista con NOTICE) y quita todo privilegio de
--     anon/authenticated. Solo la Edge Function (service_role) accede.
--   * Quita EXECUTE a anon/authenticated en TODAS las funciones del
--     esquema public (no se borran).
--   * Saca estas tablas de la publicación supabase_realtime.
--
-- Se puede ejecutar más de una vez (idempotente).
-- Todo corre en una transacción: si algo falla, no queda nada a medias.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Funciones auxiliares de normalización (puras)
-- ---------------------------------------------------------------------
create or replace function public.app_norm_cedula(p text)
returns text language sql immutable set search_path = '' as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')), '')
$$;

create or replace function public.app_norm_phone(p text)
returns text language sql immutable set search_path = '' as $$
  select case
           when d = '' then null
           when d like '595%' and length(d) >= 11 then '0' || substr(d, 4)
           else d
         end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) s
$$;

create or replace function public.app_norm_name(p text)
returns text language sql immutable set search_path = '' as $$
  select nullif(btrim(regexp_replace(normalize(coalesce(p, ''), NFC), '\s+', ' ', 'g')), '')
$$;

-- PIN válido: 4 a 6 dígitos, no todos iguales, no secuencias (1234, 4321...)
create or replace function public.app_pin_is_valid(p text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p, '') ~ '^[0-9]{4,6}$'
     and p !~ '^(.)\1+$'
     and position(p in '01234567890') = 0
     and position(p in '09876543210') = 0
$$;

create or replace function public.app_mask_tail(p text, p_keep int default 3)
returns text language sql immutable set search_path = '' as $$
  select case
           when p is null then null
           when length(p) <= p_keep then repeat('•', length(p))
           else repeat('•', least(length(p) - p_keep, 6)) || right(p, p_keep)
         end
$$;

-- ---------------------------------------------------------------------
-- 2. Precondiciones (aborta con mensaje claro si algo no cuadra)
-- ---------------------------------------------------------------------
do $$
declare
  v_schema text;
  v_list   text;
begin
  foreach v_list in array array['topics', 'groups', 'students', 'group_memberships'] loop
    if to_regclass('public.' || v_list) is null then
      raise exception 'No existe la tabla public.%', v_list;
    end if;
  end loop;

  select n.nspname into v_schema
  from pg_extension e join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';
  if v_schema is null then
    create schema if not exists extensions;
    create extension pgcrypto with schema extensions;
  elsif v_schema <> 'extensions' then
    raise exception 'pgcrypto está en el esquema "%"; esta migración espera "extensions".', v_schema;
  end if;

  select string_agg(format('%s (x%s)', c, n), ', ') into v_list
  from (select public.app_norm_cedula(national_id) c, count(*) n
        from public.students group by 1 having count(*) > 1) x;
  if v_list is not null then
    raise exception 'Cédulas que quedarían duplicadas al normalizar: %. Corregilas antes de migrar.', v_list;
  end if;

  if exists (select 1 from public.students where public.app_norm_cedula(national_id) is null) then
    raise exception 'Hay estudiantes con cédula vacía. Corregilos antes de migrar.';
  end if;

  if exists (select 1 from public.group_memberships group by student_id having count(*) > 1) then
    raise exception 'Hay estudiantes en más de un grupo. Corregilo antes de migrar.';
  end if;

  if exists (select 1 from public.group_memberships group by group_id having count(*) > 12) then
    raise exception 'Hay grupos con más de 12 integrantes. Corregilo antes de migrar.';
  end if;

  if exists (select 1 from public.group_memberships m
             where not exists (select 1 from public.students s where s.id = m.student_id)
                or not exists (select 1 from public.groups g where g.id = m.group_id)) then
    raise exception 'Hay membresías que apuntan a estudiantes o grupos inexistentes.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Valores por defecto faltantes (ids y fechas)
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  v_type text;
  v_has_default boolean;
  v_identity "char";
begin
  for r in select * from (values ('topics', 'id'), ('groups', 'id'), ('students', 'id')) v(tbl, col) loop
    select format_type(a.atttypid, a.atttypmod), d.adbin is not null, a.attidentity
      into v_type, v_has_default, v_identity
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = format('public.%I', r.tbl)::regclass and a.attname = r.col;

    continue when v_has_default or v_identity <> '';

    if v_type = 'uuid' then
      execute format('alter table public.%I alter column %I set default gen_random_uuid()', r.tbl, r.col);
    elsif v_type in ('integer', 'bigint', 'smallint') then
      execute format('alter table public.%I alter column %I add generated by default as identity', r.tbl, r.col);
      execute format('select setval(pg_get_serial_sequence(%L, %L), coalesce((select max(%I) from public.%I), 0) + 1, false)',
                     'public.' || r.tbl, r.col, r.col, r.tbl);
    else
      raise exception 'public.%.% es de tipo % y no tiene valor por defecto.', r.tbl, r.col, v_type;
    end if;
    raise notice 'Valor por defecto agregado a public.%.%', r.tbl, r.col;
  end loop;

  for r in select * from (values ('groups', 'created_at'), ('students', 'created_at'),
                                 ('students', 'updated_at'), ('group_memberships', 'joined_at')) v(tbl, col) loop
    if exists (select 1 from pg_attribute a
               left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
               where a.attrelid = format('public.%I', r.tbl)::regclass
                 and a.attname = r.col and d.adbin is null) then
      execute format('alter table public.%I alter column %I set default now()', r.tbl, r.col);
      raise notice 'Valor por defecto now() agregado a public.%.%', r.tbl, r.col;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Columnas nuevas y normalización de datos existentes
-- ---------------------------------------------------------------------
alter table public.students add column if not exists pin_hash text;

do $$
declare v_n int;
begin
  update public.students
     set national_id = public.app_norm_cedula(national_id),
         phone       = coalesce(public.app_norm_phone(phone), phone),
         full_name   = coalesce(public.app_norm_name(full_name), full_name)
   where national_id is distinct from public.app_norm_cedula(national_id)
      or phone       is distinct from coalesce(public.app_norm_phone(phone), phone)
      or full_name   is distinct from coalesce(public.app_norm_name(full_name), full_name);
  get diagnostics v_n = row_count;
  raise notice 'Estudiantes con formato normalizado: %', v_n;
end $$;

-- ---------------------------------------------------------------------
-- 5. Garantías sobre group_memberships
-- ---------------------------------------------------------------------
do $$
declare v_att int2;
begin
  select attnum into v_att from pg_attribute
  where attrelid = 'public.group_memberships'::regclass and attname = 'student_id';

  -- Un estudiante = un grupo: índice único exactamente sobre student_id
  if not exists (select 1 from pg_index i
                 where i.indrelid = 'public.group_memberships'::regclass
                   and i.indisunique and i.indpred is null
                   and i.indnatts = 1 and i.indkey[0] = v_att) then
    create unique index group_memberships_student_id_key on public.group_memberships (student_id);
    raise notice 'Creado índice único group_memberships(student_id): la PK actual no lo garantizaba.';
  end if;

  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.group_memberships'::regclass and contype = 'f'
                   and confrelid = 'public.students'::regclass) then
    alter table public.group_memberships
      add constraint group_memberships_student_id_fkey
      foreign key (student_id) references public.students (id) on delete cascade;
    raise notice 'Creada FK group_memberships.student_id -> students.id';
  end if;

  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.group_memberships'::regclass and contype = 'f'
                   and confrelid = 'public.groups'::regclass) then
    alter table public.group_memberships
      add constraint group_memberships_group_id_fkey
      foreign key (group_id) references public.groups (id);
    raise notice 'Creada FK group_memberships.group_id -> groups.id';
  end if;
end $$;

create index if not exists group_memberships_group_id_idx on public.group_memberships (group_id);

-- ---------------------------------------------------------------------
-- 6. Tablas nuevas
-- ---------------------------------------------------------------------
-- 6.1 Configuración global (una sola fila)
create table if not exists public.app_settings (
  id                 boolean primary key default true
                     constraint app_settings_single_row check (id),
  registration_open  boolean not null default true,
  group_changes_open boolean not null default true,
  updated_at         timestamptz not null default now()
);
insert into public.app_settings (id) values (true) on conflict (id) do nothing;

-- 6.2 Sesiones de estudiantes (solo se guarda el hash SHA-256 del token)
do $$
declare v_type text;
begin
  if to_regclass('public.student_sessions') is null then
    select format_type(atttypid, atttypmod) into v_type
    from pg_attribute where attrelid = 'public.students'::regclass and attname = 'id';
    execute format($f$
      create table public.student_sessions (
        id           uuid primary key default gen_random_uuid(),
        student_id   %s not null references public.students (id) on delete cascade,
        token_hash   text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
        created_at   timestamptz not null default now(),
        last_seen_at timestamptz not null default now(),
        expires_at   timestamptz not null
      )$f$, v_type);
  end if;
end $$;
create index if not exists student_sessions_student_id_idx on public.student_sessions (student_id);
create index if not exists student_sessions_expires_at_idx on public.student_sessions (expires_at);

-- 6.3 Sesiones del administrador
create table if not exists public.admin_sessions (
  id         uuid primary key default gen_random_uuid(),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  ip         text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists admin_sessions_expires_at_idx on public.admin_sessions (expires_at);

-- 6.4 Eventos para limitar intentos (fuerza bruta / spam)
create table if not exists public.auth_events (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('student_login_fail', 'admin_login_fail', 'register')),
  subject    text,
  ip         text,
  created_at timestamptz not null default now()
);
create index if not exists auth_events_kind_subject_idx on public.auth_events (kind, subject, created_at);
create index if not exists auth_events_kind_ip_idx on public.auth_events (kind, ip, created_at);
create index if not exists auth_events_created_at_idx on public.auth_events (created_at);

-- 6.5 Los 14 temas: solo inserta los números que falten (no modifica existentes)
insert into public.topics (number, title)
select v.number, v.title
from (values
  (1,  'El Estado como Institución y su Aplicación Cotidiana'),
  (2,  'La Soberanía del Estado y los Límites Constitucionales'),
  (3,  'Los Fines del Estado en la Gestión Pública Actual'),
  (4,  'La Separación de Poderes en la Práctica Política Paraguaya'),
  (5,  'Formas de Gobierno y Debates Democráticos'),
  (6,  'La Personalidad Jurídica del Estado y su Responsabilidad Patrimonial'),
  (7,  'Tipos de Estado y el Rol de los Partidos Políticos'),
  (8,  'Formas de Estado (Unitario vs. Descentralización)'),
  (9,  'Gobiernos de De Facto y su Sombra en la Historia y el Presente'),
  (10, 'Mecanismos de Participación Ciudadana (Iniciativa, Referéndum y Plebiscito)'),
  (11, 'Sistemas de Gobierno (Presidencialismo en Paraguay)'),
  (12, 'Vigencia y Violación de Derechos y Garantías Constitucionales'),
  (13, 'Nacionalidad y Ciudadanía en la Realidad Migratoria'),
  (14, 'El Rol y la Independencia de los Supremos Poderes del Estado')
) v(number, title)
where not exists (select 1 from public.topics t where t.number = v.number);

-- ---------------------------------------------------------------------
-- 7. Triggers
-- ---------------------------------------------------------------------
-- 7.1 Normaliza y valida datos del estudiante
create or replace function public.app_trg_students_normalize()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.national_id is distinct from old.national_id then
    new.national_id := public.app_norm_cedula(new.national_id);
    if new.national_id is null or new.national_id !~ '^[0-9A-Z]{4,15}$' or new.national_id !~ '[0-9]' then
      raise exception using errcode = 'P0001', message = 'INVALID_NATIONAL_ID';
    end if;
  end if;

  if tg_op = 'INSERT' or new.phone is distinct from old.phone then
    new.phone := public.app_norm_phone(new.phone);
    if new.phone is null or length(new.phone) not between 6 and 15 then
      raise exception using errcode = 'P0001', message = 'INVALID_PHONE';
    end if;
  end if;

  if tg_op = 'INSERT' or new.full_name is distinct from old.full_name then
    new.full_name := public.app_norm_name(new.full_name);
    if new.full_name is null
       or char_length(new.full_name) not between 5 and 80
       or position(' ' in new.full_name) = 0
       or new.full_name ~ '[0-9<>"{}\[\]\\/@#$%^&*=_|~`;:!?¡¿()+]'
       or new.full_name ~ '[[:cntrl:]]' then
      raise exception using errcode = 'P0001', message = 'INVALID_NAME';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists app_students_normalize on public.students;
create trigger app_students_normalize
  before insert or update on public.students
  for each row execute function public.app_trg_students_normalize();

-- 7.2 Tope de 12 integrantes. El FOR UPDATE sobre la fila del grupo hace que
--     dos personas que intentan ocupar el último lugar entren en fila:
--     la segunda ve el conteo actualizado y recibe GROUP_FULL.
create or replace function public.app_trg_membership_capacity()
returns trigger language plpgsql set search_path = '' as $$
declare v_count int;
begin
  if tg_op = 'UPDATE' and new.group_id is not distinct from old.group_id then
    return new;
  end if;

  perform 1 from public.groups g where g.id = new.group_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'GROUP_NOT_FOUND';
  end if;

  select count(*) into v_count
  from public.group_memberships m
  where m.group_id = new.group_id and m.student_id <> new.student_id;

  if v_count >= 12 then
    raise exception using errcode = 'P0001', message = 'GROUP_FULL';
  end if;

  if tg_op = 'UPDATE' then
    new.joined_at := now();
  end if;
  return new;
end $$;

drop trigger if exists app_membership_capacity on public.group_memberships;
create trigger app_membership_capacity
  before insert or update of group_id on public.group_memberships
  for each row execute function public.app_trg_membership_capacity();

-- 7.3 Si un grupo queda sin integrantes, se elimina (su número queda libre)
create or replace function public.app_trg_membership_cleanup()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.group_id is not distinct from old.group_id then
    return null;
  end if;

  perform 1 from public.groups g where g.id = old.group_id for update;
  if found and not exists (select 1 from public.group_memberships m where m.group_id = old.group_id) then
    delete from public.groups g where g.id = old.group_id;
  end if;
  return null;
end $$;

drop trigger if exists app_membership_cleanup on public.group_memberships;
create trigger app_membership_cleanup
  after delete or update of group_id on public.group_memberships
  for each row execute function public.app_trg_membership_cleanup();

-- ---------------------------------------------------------------------
-- 8. Funciones internas
-- ---------------------------------------------------------------------
create or replace function public.app_raise(p_code text)
returns void language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = 'P0001', message = p_code;
end $$;

-- Devuelve el estudiante dueño de la sesión (opcionalmente bloqueando su fila)
create or replace function public.app_session_student(p_token_hash text, p_lock boolean default false)
returns public.students language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_sid     uuid;
  v_seen    timestamptz;
begin
  select ss.id, ss.last_seen_at into v_sid, v_seen
  from public.student_sessions ss
  where ss.token_hash = p_token_hash and ss.expires_at > now();

  if v_sid is null then
    perform public.app_raise('NOT_AUTHENTICATED');
  end if;

  if p_lock then
    select s.* into v_student
    from public.students s join public.student_sessions ss on ss.student_id = s.id
    where ss.id = v_sid
    for update of s;
  else
    select s.* into v_student
    from public.students s join public.student_sessions ss on ss.student_id = s.id
    where ss.id = v_sid;
  end if;

  if v_student.id is null then
    perform public.app_raise('NOT_AUTHENTICATED');
  end if;

  if v_seen < now() - interval '5 minutes' then
    update public.student_sessions set last_seen_at = now() where id = v_sid;
  end if;
  return v_student;
end $$;

create or replace function public.app_student_group_json(p_student_id text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
           'group_id', g.id,
           'group_number', g.group_number,
           'topic_id', t.id,
           'topic_number', t.number,
           'topic_title', t.title,
           'count', (select count(*) from public.group_memberships m2 where m2.group_id = g.id))
  from public.group_memberships m
  join public.groups g on g.id = m.group_id
  join public.topics t on t.id = g.topic_id
  where m.student_id::text = p_student_id
$$;

create or replace function public.app_login_blocked(p_subject text, p_ip text)
returns boolean language sql stable set search_path = '' as $$
  select
    (select count(*) from public.auth_events
      where kind = 'student_login_fail' and subject = p_subject
        and created_at > now() - interval '15 minutes') >= 5
    or
    (select count(*) from public.auth_events
      where kind = 'student_login_fail' and subject = p_subject
        and created_at > now() - interval '24 hours') >= 15
    or
    (p_ip is not null and
     (select count(*) from public.auth_events
       where kind = 'student_login_fail' and ip = p_ip
         and created_at > now() - interval '15 minutes') >= 40)
$$;

create or replace function public.app_new_session(p_student_id text, p_token_hash text)
returns timestamptz language plpgsql set search_path = '' as $$
declare v_expires timestamptz := now() + interval '30 days';
begin
  insert into public.student_sessions (student_id, token_hash, expires_at)
  select s.id, p_token_hash, v_expires from public.students s where s.id::text = p_student_id;
  delete from public.student_sessions where expires_at < now();
  delete from public.auth_events where created_at < now() - interval '2 days';
  return v_expires;
end $$;

-- Mueve (o agrega) un estudiante a un grupo. Quien llama debe haber
-- bloqueado la fila del estudiante. Bloquea grupos en orden fijo.
create or replace function public.app_move_student(p_student_id text, p_group_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare v_current text;
begin
  select m.group_id::text into v_current
  from public.group_memberships m where m.student_id::text = p_student_id;

  if v_current = p_group_id then
    perform public.app_raise('ALREADY_IN_GROUP');
  end if;

  perform 1 from public.groups g
  where g.id::text in (p_group_id, v_current)
  order by g.id::text
  for update;

  if not exists (select 1 from public.groups g where g.id::text = p_group_id) then
    perform public.app_raise('GROUP_NOT_FOUND');
  end if;

  if v_current is null then
    insert into public.group_memberships (student_id, group_id)
    select s.id, g.id from public.students s, public.groups g
    where s.id::text = p_student_id and g.id::text = p_group_id;
  else
    update public.group_memberships m
       set group_id = g.id
      from public.groups g
     where g.id::text = p_group_id and m.student_id::text = p_student_id;
  end if;

  return public.app_student_group_json(p_student_id);
end $$;

-- Crea un grupo con el menor número libre dentro del tema
create or replace function public.app_new_group(p_topic_id text)
returns text language plpgsql set search_path = '' as $$
declare
  v_topic record;
  v_num   int;
  v_gid   text;
begin
  select t.id into v_topic from public.topics t where t.id::text = p_topic_id for update;
  if not found then
    perform public.app_raise('TOPIC_NOT_FOUND');
  end if;

  select n into v_num
  from generate_series(1, (select count(*)::int + 1 from public.groups g where g.topic_id = v_topic.id)) n
  where not exists (select 1 from public.groups g where g.topic_id = v_topic.id and g.group_number = n)
  order by n limit 1;

  insert into public.groups (topic_id, group_number)
  values (v_topic.id, v_num)
  returning id::text into v_gid;
  return v_gid;
end $$;

-- ---------------------------------------------------------------------
-- 9. RPC para estudiantes (las llama SOLO la Edge Function)
-- ---------------------------------------------------------------------
create or replace function public.app_state(p_token_hash text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_me    public.students;
  v_me_id text;
  v_auth  boolean := false;
begin
  if p_token_hash is not null then
    begin
      v_me := public.app_session_student(p_token_hash);
      v_auth := true;
      v_me_id := v_me.id::text;
    exception when sqlstate 'P0001' then
      if sqlerrm <> 'NOT_AUTHENTICATED' then raise; end if;
    end;
  end if;

  return jsonb_build_object(
    'limits', jsonb_build_object('min', 8, 'max', 12),
    'settings', (select jsonb_build_object('registration_open', s.registration_open,
                                           'group_changes_open', s.group_changes_open)
                 from public.app_settings s where s.id),
    'authenticated', v_auth,
    'me', case when v_auth then jsonb_build_object(
            'full_name', v_me.full_name,
            'national_id_masked', public.app_mask_tail(v_me.national_id),
            'phone_masked', public.app_mask_tail(v_me.phone),
            'group', public.app_student_group_json(v_me_id)) end,
    'topics', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id,
               'number', t.number,
               'title', t.title,
               'description', t.description,
               'groups', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', g.id,
                          'number', g.group_number,
                          'count', (select count(*) from public.group_memberships m where m.group_id = g.id),
                          'members', case when v_auth then coalesce((
                            select jsonb_agg(jsonb_build_object('name', s.full_name,
                                                                'is_me', s.id::text = v_me_id)
                                             order by m.joined_at, s.full_name)
                            from public.group_memberships m
                            join public.students s on s.id = m.student_id
                            where m.group_id = g.id), '[]'::jsonb) end)
                        order by g.group_number)
                 from public.groups g where g.topic_id = t.id), '[]'::jsonb))
             order by t.number)
      from public.topics t), '[]'::jsonb),
    'server_time', now());
end $$;

create or replace function public.app_register(
  p_full_name text, p_national_id text, p_phone text, p_pin text,
  p_token_hash text, p_ip text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_new     public.students;
  v_expires timestamptz;
begin
  if not (select registration_open from public.app_settings where id) then
    perform public.app_raise('REGISTRATION_CLOSED');
  end if;

  if p_ip is not null and (select count(*) from public.auth_events
                           where kind = 'register' and ip = p_ip
                             and created_at > now() - interval '10 minutes') >= 100 then
    perform public.app_raise('RATE_LIMITED');
  end if;

  if not public.app_pin_is_valid(p_pin) then
    perform public.app_raise('INVALID_PIN');
  end if;

  if exists (select 1 from public.students where national_id = public.app_norm_cedula(p_national_id)) then
    perform public.app_raise('ALREADY_REGISTERED');
  end if;

  begin
    insert into public.students (full_name, national_id, phone, pin_hash)
    values (p_full_name, p_national_id, p_phone,
            extensions.crypt(p_pin, extensions.gen_salt('bf', 8)))
    returning * into v_new;
  exception when unique_violation then
    perform public.app_raise('ALREADY_REGISTERED');
  end;

  v_expires := public.app_new_session(v_new.id::text, p_token_hash);
  insert into public.auth_events (kind, subject, ip) values ('register', v_new.national_id, p_ip);
  return jsonb_build_object('ok', true, 'expires_at', v_expires);
end $$;

create or replace function public.app_login(
  p_national_id text, p_pin text, p_token_hash text, p_ip text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_ced     text := public.app_norm_cedula(p_national_id);
  v_student public.students;
  v_ok      boolean := false;
begin
  if public.app_login_blocked(v_ced, p_ip) then
    return jsonb_build_object('ok', false, 'error', 'TOO_MANY_ATTEMPTS');
  end if;

  select * into v_student from public.students where national_id = v_ced;

  if v_student.id is null or v_student.pin_hash is null then
    -- Mismo costo de CPU exista o no la cédula
    perform extensions.crypt(coalesce(p_pin, ''), '$2a$08$abcdefghijklmnopqrstuu');
    if v_student.id is not null then
      return jsonb_build_object('ok', false, 'error', 'NEEDS_PIN_SETUP');
    end if;
  else
    v_ok := extensions.crypt(coalesce(p_pin, ''), v_student.pin_hash) = v_student.pin_hash;
  end if;

  if not v_ok then
    insert into public.auth_events (kind, subject, ip) values ('student_login_fail', v_ced, p_ip);
    return jsonb_build_object('ok', false, 'error', 'INVALID_CREDENTIALS');
  end if;

  delete from public.auth_events where kind = 'student_login_fail' and subject = v_ced;
  return jsonb_build_object('ok', true,
                            'expires_at', public.app_new_session(v_student.id::text, p_token_hash));
end $$;

-- Para estudiantes que ya existían sin PIN: se valida cédula + teléfono UNA vez
create or replace function public.app_claim_pin(
  p_national_id text, p_phone text, p_pin text, p_token_hash text, p_ip text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_ced     text := public.app_norm_cedula(p_national_id);
  v_student public.students;
begin
  if public.app_login_blocked(v_ced, p_ip) then
    return jsonb_build_object('ok', false, 'error', 'TOO_MANY_ATTEMPTS');
  end if;
  if not public.app_pin_is_valid(p_pin) then
    perform public.app_raise('INVALID_PIN');
  end if;

  select * into v_student from public.students where national_id = v_ced for update;

  if v_student.id is null or v_student.phone is distinct from public.app_norm_phone(p_phone) then
    insert into public.auth_events (kind, subject, ip) values ('student_login_fail', v_ced, p_ip);
    return jsonb_build_object('ok', false, 'error', 'CLAIM_MISMATCH');
  end if;
  if v_student.pin_hash is not null then
    return jsonb_build_object('ok', false, 'error', 'PIN_ALREADY_SET');
  end if;

  update public.students
     set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 8))
   where id = v_student.id;
  delete from public.auth_events where kind = 'student_login_fail' and subject = v_ced;
  return jsonb_build_object('ok', true,
                            'expires_at', public.app_new_session(v_student.id::text, p_token_hash));
end $$;

create or replace function public.app_logout(p_token_hash text)
returns jsonb language sql set search_path = '' as $$
  with d as (delete from public.student_sessions where token_hash = p_token_hash returning 1)
  select jsonb_build_object('ok', true)
$$;

create or replace function public.app_join_group(p_token_hash text, p_group_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare v_student public.students;
begin
  v_student := public.app_session_student(p_token_hash, true);
  if not (select group_changes_open from public.app_settings where id) then
    perform public.app_raise('CHANGES_CLOSED');
  end if;
  return public.app_move_student(v_student.id::text, p_group_id);
end $$;

create or replace function public.app_create_group(p_token_hash text, p_topic_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_gid     text;
begin
  v_student := public.app_session_student(p_token_hash, true);
  if not (select group_changes_open from public.app_settings where id) then
    perform public.app_raise('CHANGES_CLOSED');
  end if;
  v_gid := public.app_new_group(p_topic_id);
  return public.app_move_student(v_student.id::text, v_gid);
end $$;

create or replace function public.app_leave_group(p_token_hash text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_current text;
begin
  v_student := public.app_session_student(p_token_hash, true);
  if not (select group_changes_open from public.app_settings where id) then
    perform public.app_raise('CHANGES_CLOSED');
  end if;

  select m.group_id::text into v_current
  from public.group_memberships m where m.student_id = v_student.id;
  if v_current is null then
    perform public.app_raise('NOT_IN_GROUP');
  end if;

  perform 1 from public.groups g where g.id::text = v_current for update;
  delete from public.group_memberships where student_id = v_student.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_update_profile(
  p_token_hash text, p_full_name text default null, p_phone text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare v_student public.students;
begin
  v_student := public.app_session_student(p_token_hash, true);
  update public.students
     set full_name = coalesce(nullif(btrim(p_full_name), ''), full_name),
         phone     = coalesce(nullif(btrim(p_phone), ''), phone)
   where id = v_student.id
  returning * into v_student;
  return jsonb_build_object('ok', true,
                            'full_name', v_student.full_name,
                            'phone_masked', public.app_mask_tail(v_student.phone));
end $$;

create or replace function public.app_change_pin(
  p_token_hash text, p_current_pin text, p_new_pin text, p_ip text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare v_student public.students;
begin
  v_student := public.app_session_student(p_token_hash, true);
  if public.app_login_blocked(v_student.national_id, p_ip) then
    return jsonb_build_object('ok', false, 'error', 'TOO_MANY_ATTEMPTS');
  end if;
  if v_student.pin_hash is null
     or extensions.crypt(coalesce(p_current_pin, ''), v_student.pin_hash) <> v_student.pin_hash then
    insert into public.auth_events (kind, subject, ip)
    values ('student_login_fail', v_student.national_id, p_ip);
    return jsonb_build_object('ok', false, 'error', 'WRONG_CURRENT_PIN');
  end if;
  if not public.app_pin_is_valid(p_new_pin) then
    perform public.app_raise('INVALID_PIN');
  end if;

  update public.students
     set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 8))
   where id = v_student.id;
  delete from public.student_sessions
   where student_id = v_student.id and token_hash <> p_token_hash;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 10. RPC para el administrador
--     La contraseña se valida en la Edge Function (secreto ADMIN_PASSWORD);
--     acá solo se guardan sesiones con hash y se limita la fuerza bruta.
-- ---------------------------------------------------------------------
create or replace function public.app_admin_login_allowed(p_ip text default null)
returns boolean language sql stable set search_path = '' as $$
  select (select count(*) from public.auth_events
           where kind = 'admin_login_fail' and created_at > now() - interval '15 minutes') < 20
     and (p_ip is null or
          (select count(*) from public.auth_events
            where kind = 'admin_login_fail' and ip = p_ip
              and created_at > now() - interval '15 minutes') < 5)
$$;

create or replace function public.app_admin_login_failed(p_ip text default null)
returns void language sql set search_path = '' as $$
  insert into public.auth_events (kind, ip) values ('admin_login_fail', p_ip);
$$;

create or replace function public.app_admin_create_session(p_token_hash text, p_ip text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare v_expires timestamptz := now() + interval '12 hours';
begin
  delete from public.admin_sessions where expires_at < now();
  insert into public.admin_sessions (token_hash, ip, expires_at) values (p_token_hash, p_ip, v_expires);
  return jsonb_build_object('ok', true, 'expires_at', v_expires);
end $$;

create or replace function public.app_admin_assert(p_token_hash text)
returns void language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.admin_sessions
                 where token_hash = p_token_hash and expires_at > now()) then
    perform public.app_raise('NOT_AUTHENTICATED');
  end if;
end $$;

create or replace function public.app_admin_logout(p_token_hash text)
returns jsonb language sql set search_path = '' as $$
  with d as (delete from public.admin_sessions where token_hash = p_token_hash returning 1)
  select jsonb_build_object('ok', true)
$$;

create or replace function public.app_admin_lock_student(p_student_id text)
returns public.students language plpgsql set search_path = '' as $$
declare v_student public.students;
begin
  select * into v_student from public.students s where s.id::text = p_student_id for update;
  if v_student.id is null then
    perform public.app_raise('STUDENT_NOT_FOUND');
  end if;
  return v_student;
end $$;

create or replace function public.app_admin_state(p_token_hash text)
returns jsonb language plpgsql set search_path = '' as $$
begin
  perform public.app_admin_assert(p_token_hash);
  return jsonb_build_object(
    'limits', jsonb_build_object('min', 8, 'max', 12),
    'settings', (select to_jsonb(s) - 'id' from public.app_settings s where s.id),
    'topics', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'number', t.number, 'title', t.title)
                                         order by t.number) from public.topics t), '[]'::jsonb),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', g.id, 'topic_id', g.topic_id, 'number', g.group_number, 'created_at', g.created_at)
             order by g.topic_id, g.group_number)
      from public.groups g), '[]'::jsonb),
    'students', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id,
               'full_name', s.full_name,
               'national_id', s.national_id,
               'phone', s.phone,
               'created_at', s.created_at,
               'updated_at', s.updated_at,
               'has_pin', s.pin_hash is not null,
               'group_id', m.group_id,
               'joined_at', m.joined_at,
               'failed_logins', (select count(*) from public.auth_events e
                                 where e.kind = 'student_login_fail' and e.subject = s.national_id
                                   and e.created_at > now() - interval '24 hours'))
             order by s.full_name)
      from public.students s
      left join public.group_memberships m on m.student_id = s.id), '[]'::jsonb),
    'server_time', now());
end $$;

create or replace function public.app_admin_move_student(p_token_hash text, p_student_id text, p_group_id text)
returns jsonb language plpgsql set search_path = '' as $$
begin
  perform public.app_admin_assert(p_token_hash);
  perform public.app_admin_lock_student(p_student_id);
  return public.app_move_student(p_student_id, p_group_id);
end $$;

create or replace function public.app_admin_remove_from_group(p_token_hash text, p_student_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare v_current text;
begin
  perform public.app_admin_assert(p_token_hash);
  perform public.app_admin_lock_student(p_student_id);
  select m.group_id::text into v_current
  from public.group_memberships m where m.student_id::text = p_student_id;
  if v_current is null then
    perform public.app_raise('NOT_IN_GROUP');
  end if;
  perform 1 from public.groups g where g.id::text = v_current for update;
  delete from public.group_memberships m where m.student_id::text = p_student_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_admin_update_student(
  p_token_hash text, p_student_id text,
  p_full_name text default null, p_national_id text default null, p_phone text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare v_student public.students;
begin
  perform public.app_admin_assert(p_token_hash);
  v_student := public.app_admin_lock_student(p_student_id);
  if p_national_id is not null
     and exists (select 1 from public.students s
                 where s.national_id = public.app_norm_cedula(p_national_id)
                   and s.id <> v_student.id) then
    perform public.app_raise('NATIONAL_ID_TAKEN');
  end if;
  update public.students
     set full_name   = coalesce(nullif(btrim(p_full_name), ''), full_name),
         national_id = coalesce(nullif(btrim(p_national_id), ''), national_id),
         phone       = coalesce(nullif(btrim(p_phone), ''), phone)
   where id = v_student.id;
  return jsonb_build_object('ok', true);
exception when unique_violation then
  perform public.app_raise('NATIONAL_ID_TAKEN');
  return null;
end $$;

create or replace function public.app_admin_reset_pin(p_token_hash text, p_student_id text, p_new_pin text)
returns jsonb language plpgsql set search_path = '' as $$
declare v_student public.students;
begin
  perform public.app_admin_assert(p_token_hash);
  v_student := public.app_admin_lock_student(p_student_id);
  if not public.app_pin_is_valid(p_new_pin) then
    perform public.app_raise('INVALID_PIN');
  end if;
  update public.students
     set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 8))
   where id = v_student.id;
  delete from public.student_sessions where student_id = v_student.id;
  delete from public.auth_events where kind = 'student_login_fail' and subject = v_student.national_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_admin_unlock_student(p_token_hash text, p_student_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare v_student public.students;
begin
  perform public.app_admin_assert(p_token_hash);
  v_student := public.app_admin_lock_student(p_student_id);
  delete from public.auth_events where kind = 'student_login_fail' and subject = v_student.national_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_admin_delete_student(p_token_hash text, p_student_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_current text;
begin
  perform public.app_admin_assert(p_token_hash);
  v_student := public.app_admin_lock_student(p_student_id);
  select m.group_id::text into v_current
  from public.group_memberships m where m.student_id = v_student.id;
  if v_current is not null then
    perform 1 from public.groups g where g.id::text = v_current for update;
    delete from public.group_memberships where student_id = v_student.id;
  end if;
  delete from public.student_sessions where student_id = v_student.id;
  delete from public.students where id = v_student.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_admin_create_group(p_token_hash text, p_topic_id text)
returns jsonb language plpgsql set search_path = '' as $$
begin
  perform public.app_admin_assert(p_token_hash);
  return jsonb_build_object('ok', true, 'group_id', public.app_new_group(p_topic_id));
end $$;

create or replace function public.app_admin_delete_group(p_token_hash text, p_group_id text)
returns jsonb language plpgsql set search_path = '' as $$
begin
  perform public.app_admin_assert(p_token_hash);
  -- orden de bloqueo: estudiantes -> grupo (igual que el resto)
  perform 1 from public.students s
  where s.id in (select m.student_id from public.group_memberships m where m.group_id::text = p_group_id)
  order by s.id::text
  for update;
  perform 1 from public.groups g where g.id::text = p_group_id for update;
  if not found then
    perform public.app_raise('GROUP_NOT_FOUND');
  end if;
  delete from public.group_memberships m where m.group_id::text = p_group_id;
  delete from public.groups g where g.id::text = p_group_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_admin_set_settings(
  p_token_hash text, p_registration_open boolean default null, p_group_changes_open boolean default null)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  perform public.app_admin_assert(p_token_hash);
  update public.app_settings
     set registration_open  = coalesce(p_registration_open, registration_open),
         group_changes_open = coalesce(p_group_changes_open, group_changes_open),
         updated_at = now()
   where id
  returning to_jsonb(app_settings) - 'id' into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- 11. Cierre de seguridad
-- ---------------------------------------------------------------------
do $$
declare
  r   record;
  tbl text;
  v_tables text[] := array['topics', 'groups', 'students', 'group_memberships',
                           'app_settings', 'student_sessions', 'admin_sessions', 'auth_events'];
begin
  -- RLS activado + sin privilegios para anon/authenticated
  foreach tbl in array v_tables loop
    execute format('alter table public.%I enable row level security', tbl);
    execute format('revoke all on table public.%I from public, anon, authenticated', tbl);
    execute format('grant select, insert, update, delete on table public.%I to service_role', tbl);
  end loop;

  -- Políticas existentes en estas tablas: se eliminan (quedan listadas)
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename = any (v_tables) loop
    raise notice 'Eliminando política "%" de public.%', r.policyname, r.tablename;
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;

  -- Ninguna función de public ejecutable desde el navegador
  for r in select p.oid::regprocedure as f from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
  end loop;

  -- Vistas en public: sin acceso para anon/authenticated
  for r in select viewname from pg_views where schemaname = 'public' loop
    execute format('revoke all on public.%I from public, anon, authenticated', r.viewname);
    raise notice 'Vista public.%: se quitaron privilegios de anon/authenticated', r.viewname;
  end loop;

  -- Realtime: estas tablas no se transmiten
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    for r in select tablename from pg_publication_tables
             where pubname = 'supabase_realtime' and schemaname = 'public'
               and tablename = any (v_tables) loop
      execute format('alter publication supabase_realtime drop table public.%I', r.tablename);
      raise notice 'Tabla public.% quitada de supabase_realtime', r.tablename;
    end loop;
  end if;

  -- Aviso sobre otras tablas de public que sigan expuestas
  for r in select distinct table_name from information_schema.role_table_grants
           where table_schema = 'public' and grantee in ('anon', 'authenticated')
             and table_name <> all (v_tables) loop
    raise notice 'ATENCIÓN: public.% (no es de esta app) sigue con privilegios para anon/authenticated', r.table_name;
  end loop;
end $$;

-- Funciones futuras en public: que no queden ejecutables por anon por defecto
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

commit;

-- Que la API (PostgREST) vea las funciones nuevas
notify pgrst, 'reload schema';
