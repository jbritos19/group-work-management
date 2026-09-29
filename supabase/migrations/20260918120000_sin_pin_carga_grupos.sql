-- =====================================================================
-- MIGRACIÓN 2: entrada solo con cédula + carga de grupos por el admin
-- Requiere haber aplicado antes 20260916120000_grupos_seguros.sql
--
-- QUÉ HACE:
--   * Quita el PIN: los estudiantes entran solo con su cédula.
--     Se elimina la columna students.pin_hash y las funciones de PIN.
--   * students.phone pasa a ser opcional (para estudiantes que cargue el
--     administrador sin teléfono; la app se lo pide al entrar).
--   * groups.locked: grupo cerrado por el administrador (los estudiantes
--     no pueden entrar ni salir; el administrador sí).
--   * Tabla nueva activity_log: historial de movimientos.
--   * Función nueva para cargar un grupo ya armado desde el panel.
--   * No borra estudiantes, grupos, temas ni membresías.
-- Se puede ejecutar más de una vez. Todo en una transacción.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.app_move_student(text,text)') is null then
    raise exception 'Primero hay que aplicar la migración 20260916120000_grupos_seguros.sql';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Estructura
-- ---------------------------------------------------------------------
alter table public.students alter column phone drop not null;
alter table public.groups add column if not exists locked boolean not null default false;

do $$
declare v_type text;
begin
  if to_regclass('public.activity_log') is null then
    select format_type(atttypid, atttypmod) into v_type
    from pg_attribute where attrelid = 'public.students'::regclass and attname = 'id';
    execute format($f$
      create table public.activity_log (
        id           bigint generated always as identity primary key,
        created_at   timestamptz not null default now(),
        actor        text not null check (actor in ('estudiante', 'admin')),
        student_id   %s references public.students (id) on delete set null,
        student_name text,
        action       text not null,
        detail       text
      )$f$, v_type);
  end if;
end $$;
create index if not exists activity_log_created_at_idx on public.activity_log (created_at desc);
create index if not exists activity_log_student_id_idx on public.activity_log (student_id);

-- ---------------------------------------------------------------------
-- 2. Se quitan las funciones de PIN (el resto se reemplaza abajo)
-- ---------------------------------------------------------------------
drop function if exists public.app_register(text, text, text, text, text, text);
drop function if exists public.app_login(text, text, text, text);
drop function if exists public.app_claim_pin(text, text, text, text, text);
drop function if exists public.app_change_pin(text, text, text, text);
drop function if exists public.app_admin_reset_pin(text, text, text);
drop function if exists public.app_admin_unlock_student(text, text);
drop function if exists public.app_login_blocked(text, text);
drop function if exists public.app_pin_is_valid(text);

-- ---------------------------------------------------------------------
-- 3. Trigger de estudiantes: teléfono opcional
-- ---------------------------------------------------------------------
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
    if new.phone is not null and length(new.phone) not between 6 and 15 then
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

-- ---------------------------------------------------------------------
-- 4. Auxiliares
-- ---------------------------------------------------------------------
create or replace function public.app_group_label(p_group_id text)
returns text language sql stable set search_path = '' as $$
  select format('Tema %s, Grupo %s', t.number, g.group_number)
  from public.groups g join public.topics t on t.id = g.topic_id
  where g.id::text = p_group_id
$$;

create or replace function public.app_current_group(p_student_id text)
returns text language sql stable set search_path = '' as $$
  select m.group_id::text from public.group_memberships m where m.student_id::text = p_student_id
$$;

create or replace function public.app_log(p_actor text, p_student_id text, p_action text, p_detail text default null)
returns void language plpgsql set search_path = '' as $$
begin
  insert into public.activity_log (actor, student_id, student_name, action, detail)
  select p_actor, s.id, s.full_name, p_action, p_detail
  from public.students s where s.id::text = p_student_id;
  if not found then
    insert into public.activity_log (actor, action, detail) values (p_actor, p_action, p_detail);
  end if;
end $$;

create or replace function public.app_ip_blocked(p_kind text, p_ip text, p_max int, p_window interval)
returns boolean language sql stable set search_path = '' as $$
  select p_ip is not null and
         (select count(*) from public.auth_events
          where kind = p_kind and ip = p_ip and created_at > now() - p_window) >= p_max
$$;

create or replace function public.app_student_group_json(p_student_id text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
           'group_id', g.id,
           'group_number', g.group_number,
           'topic_id', t.id,
           'topic_number', t.number,
           'topic_title', t.title,
           'locked', g.locked,
           'count', (select count(*) from public.group_memberships m2 where m2.group_id = g.id))
  from public.group_memberships m
  join public.groups g on g.id = m.group_id
  join public.topics t on t.id = g.topic_id
  where m.student_id::text = p_student_id
$$;

-- ---------------------------------------------------------------------
-- 5. Estudiantes
-- ---------------------------------------------------------------------
-- Entrar solo con la cédula
create or replace function public.app_enter(p_national_id text, p_token_hash text, p_ip text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_ced     text := public.app_norm_cedula(p_national_id);
  v_student public.students;
begin
  if v_ced is null or v_ced !~ '^[0-9A-Z]{4,15}$' or v_ced !~ '[0-9]' then
    perform public.app_raise('INVALID_NATIONAL_ID');
  end if;
  -- límite generoso (muchos estudiantes comparten el wifi de la facultad)
  if public.app_ip_blocked('student_login_fail', p_ip, 300, interval '15 minutes') then
    return jsonb_build_object('ok', false, 'error', 'TOO_MANY_ATTEMPTS');
  end if;

  select * into v_student from public.students where national_id = v_ced;
  if v_student.id is null then
    insert into public.auth_events (kind, subject, ip) values ('student_login_fail', v_ced, p_ip);
    return jsonb_build_object('ok', false, 'error', 'NOT_REGISTERED');
  end if;

  return jsonb_build_object('ok', true,
                            'full_name', v_student.full_name,
                            'expires_at', public.app_new_session(v_student.id::text, p_token_hash));
end $$;

create or replace function public.app_register(
  p_full_name text, p_national_id text, p_phone text, p_token_hash text, p_ip text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_phone   text := public.app_norm_phone(p_phone);
begin
  -- Si la cédula ya existe, simplemente entra (no se modifica nada)
  select * into v_student from public.students where national_id = public.app_norm_cedula(p_national_id);
  if v_student.id is not null then
    return jsonb_build_object('ok', true, 'existed', true, 'full_name', v_student.full_name,
                              'expires_at', public.app_new_session(v_student.id::text, p_token_hash));
  end if;

  if not (select registration_open from public.app_settings where id) then
    perform public.app_raise('REGISTRATION_CLOSED');
  end if;
  if public.app_ip_blocked('register', p_ip, 300, interval '10 minutes') then
    perform public.app_raise('RATE_LIMITED');
  end if;
  if v_phone is null or length(v_phone) not between 6 and 15 then
    perform public.app_raise('INVALID_PHONE');
  end if;

  begin
    insert into public.students (full_name, national_id, phone)
    values (p_full_name, p_national_id, v_phone)
    returning * into v_student;
  exception when unique_violation then
    select * into v_student from public.students where national_id = public.app_norm_cedula(p_national_id);
    return jsonb_build_object('ok', true, 'existed', true, 'full_name', v_student.full_name,
                              'expires_at', public.app_new_session(v_student.id::text, p_token_hash));
  end;

  insert into public.auth_events (kind, subject, ip) values ('register', v_student.national_id, p_ip);
  perform public.app_log('estudiante', v_student.id::text, 'Se registró');
  return jsonb_build_object('ok', true, 'existed', false, 'full_name', v_student.full_name,
                            'expires_at', public.app_new_session(v_student.id::text, p_token_hash));
end $$;

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
            'phone_missing', v_me.phone is null,
            'group', public.app_student_group_json(v_me_id)) end,
    'topics', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id,
               'number', t.number,
               'title', t.title,
               'description', nullif(t.description, ''),
               'groups', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', g.id,
                          'number', g.group_number,
                          'locked', g.locked,
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

-- Verifica que el estudiante pueda cambiar de grupo
create or replace function public.app_student_can_change(p_student_id text, p_target_group text)
returns void language plpgsql set search_path = '' as $$
begin
  if not (select group_changes_open from public.app_settings where id) then
    perform public.app_raise('CHANGES_CLOSED');
  end if;
  if exists (select 1 from public.group_memberships m join public.groups g on g.id = m.group_id
             where m.student_id::text = p_student_id and g.locked) then
    perform public.app_raise('GROUP_LOCKED_MINE');
  end if;
  if p_target_group is not null
     and exists (select 1 from public.groups g where g.id::text = p_target_group and g.locked) then
    perform public.app_raise('GROUP_LOCKED');
  end if;
end $$;

create or replace function public.app_join_group(p_token_hash text, p_group_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_from    text;
  v_res     jsonb;
begin
  v_student := public.app_session_student(p_token_hash, true);
  if public.app_current_group(v_student.id::text) = p_group_id then
    perform public.app_raise('ALREADY_IN_GROUP');
  end if;
  perform public.app_student_can_change(v_student.id::text, p_group_id);
  v_from := public.app_group_label(public.app_current_group(v_student.id::text));
  v_res := public.app_move_student(v_student.id::text, p_group_id);
  perform public.app_log('estudiante', v_student.id::text,
    case when v_from is null then 'Se unió' else 'Se cambió' end,
    concat_ws(' → ', v_from, public.app_group_label(p_group_id)));
  return v_res;
end $$;

create or replace function public.app_create_group(p_token_hash text, p_topic_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_gid     text;
  v_from    text;
begin
  v_student := public.app_session_student(p_token_hash, true);
  perform public.app_student_can_change(v_student.id::text, null);
  v_from := public.app_group_label(public.app_current_group(v_student.id::text));
  v_gid := public.app_new_group(p_topic_id);
  perform public.app_move_student(v_student.id::text, v_gid);
  perform public.app_log('estudiante', v_student.id::text, 'Creó un grupo',
    concat_ws(' → ', v_from, public.app_group_label(v_gid)));
  return public.app_student_group_json(v_student.id::text);
end $$;

create or replace function public.app_leave_group(p_token_hash text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_current text;
  v_label   text;
begin
  v_student := public.app_session_student(p_token_hash, true);
  v_current := public.app_current_group(v_student.id::text);
  if v_current is null then
    perform public.app_raise('NOT_IN_GROUP');
  end if;
  perform public.app_student_can_change(v_student.id::text, null);
  v_label := public.app_group_label(v_current);
  perform 1 from public.groups g where g.id::text = v_current for update;
  delete from public.group_memberships where student_id = v_student.id;
  perform public.app_log('estudiante', v_student.id::text, 'Abandonó', v_label);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_update_profile(
  p_token_hash text, p_full_name text default null, p_phone text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_old     public.students;
  v_changes text[] := '{}';
begin
  v_old := public.app_session_student(p_token_hash, true);
  if nullif(btrim(p_phone), '') is not null and public.app_norm_phone(p_phone) is null then
    perform public.app_raise('INVALID_PHONE');
  end if;
  update public.students
     set full_name = coalesce(nullif(btrim(p_full_name), ''), full_name),
         phone     = coalesce(nullif(btrim(p_phone), ''), phone)
   where id = v_old.id
  returning * into v_student;
  if v_student.full_name is distinct from v_old.full_name then
    v_changes := v_changes || format('nombre: %s → %s', v_old.full_name, v_student.full_name);
  end if;
  if v_student.phone is distinct from v_old.phone then
    v_changes := v_changes || 'teléfono'::text;
  end if;
  if cardinality(v_changes) > 0 then
    perform public.app_log('estudiante', v_student.id::text, 'Actualizó sus datos', array_to_string(v_changes, '; '));
  end if;
  return jsonb_build_object('ok', true,
                            'full_name', v_student.full_name,
                            'phone_masked', public.app_mask_tail(v_student.phone));
end $$;

-- ---------------------------------------------------------------------
-- 6. Administrador
-- ---------------------------------------------------------------------
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
               'id', g.id, 'topic_id', g.topic_id, 'number', g.group_number,
               'locked', g.locked, 'created_at', g.created_at)
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
               'group_id', m.group_id,
               'joined_at', m.joined_at)
             order by s.full_name)
      from public.students s
      left join public.group_memberships m on m.student_id = s.id), '[]'::jsonb),
    'activity', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', a.created_at, 'actor', a.actor, 'student_id', a.student_id,
               'name', a.student_name, 'action', a.action, 'detail', a.detail)
             order by a.created_at desc, a.id desc)
      from (select * from public.activity_log order by created_at desc, id desc limit 300) a), '[]'::jsonb),
    'server_time', now());
end $$;

create or replace function public.app_admin_move_student(p_token_hash text, p_student_id text, p_group_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_from text;
  v_res  jsonb;
begin
  perform public.app_admin_assert(p_token_hash);
  perform public.app_admin_lock_student(p_student_id);
  v_from := public.app_group_label(public.app_current_group(p_student_id));
  v_res := public.app_move_student(p_student_id, p_group_id);
  perform public.app_log('admin', p_student_id, case when v_from is null then 'Asignado' else 'Movido' end,
                         concat_ws(' → ', v_from, public.app_group_label(p_group_id)));
  return v_res;
end $$;

create or replace function public.app_admin_remove_from_group(p_token_hash text, p_student_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_current text;
  v_label   text;
begin
  perform public.app_admin_assert(p_token_hash);
  perform public.app_admin_lock_student(p_student_id);
  v_current := public.app_current_group(p_student_id);
  if v_current is null then
    perform public.app_raise('NOT_IN_GROUP');
  end if;
  v_label := public.app_group_label(v_current);
  perform 1 from public.groups g where g.id::text = v_current for update;
  delete from public.group_memberships m where m.student_id::text = p_student_id;
  perform public.app_log('admin', p_student_id, 'Quitado del grupo', v_label);
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
  if nullif(btrim(p_phone), '') is not null and public.app_norm_phone(p_phone) is null then
    perform public.app_raise('INVALID_PHONE');
  end if;
  update public.students
     set full_name   = coalesce(nullif(btrim(p_full_name), ''), full_name),
         national_id = coalesce(nullif(btrim(p_national_id), ''), national_id),
         phone       = coalesce(nullif(btrim(p_phone), ''), phone)
   where id = v_student.id;
  perform public.app_log('admin', p_student_id, 'Datos corregidos');
  return jsonb_build_object('ok', true);
exception when unique_violation then
  perform public.app_raise('NATIONAL_ID_TAKEN');
  return null;
end $$;

create or replace function public.app_admin_delete_student(p_token_hash text, p_student_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_student public.students;
  v_current text;
begin
  perform public.app_admin_assert(p_token_hash);
  v_student := public.app_admin_lock_student(p_student_id);
  v_current := public.app_current_group(p_student_id);
  perform public.app_log('admin', p_student_id, 'Registro eliminado',
                         concat_ws(', ', 'CI ' || v_student.national_id, public.app_group_label(v_current)));
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
declare v_gid text;
begin
  perform public.app_admin_assert(p_token_hash);
  v_gid := public.app_new_group(p_topic_id);
  perform public.app_log('admin', null, 'Grupo creado', public.app_group_label(v_gid));
  return jsonb_build_object('ok', true, 'group_id', v_gid);
end $$;

create or replace function public.app_admin_delete_group(p_token_hash text, p_group_id text)
returns jsonb language plpgsql set search_path = '' as $$
declare v_label text;
begin
  perform public.app_admin_assert(p_token_hash);
  perform 1 from public.students s
  where s.id in (select m.student_id from public.group_memberships m where m.group_id::text = p_group_id)
  order by s.id::text
  for update;
  perform 1 from public.groups g where g.id::text = p_group_id for update;
  if not found then
    perform public.app_raise('GROUP_NOT_FOUND');
  end if;
  v_label := public.app_group_label(p_group_id);
  delete from public.group_memberships m where m.group_id::text = p_group_id;
  delete from public.groups g where g.id::text = p_group_id;
  perform public.app_log('admin', null, 'Grupo eliminado', v_label);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_admin_set_group_lock(p_token_hash text, p_group_id text, p_locked boolean)
returns jsonb language plpgsql set search_path = '' as $$
begin
  perform public.app_admin_assert(p_token_hash);
  update public.groups g set locked = coalesce(p_locked, false) where g.id::text = p_group_id;
  if not found then
    perform public.app_raise('GROUP_NOT_FOUND');
  end if;
  perform public.app_log('admin', null, case when p_locked then 'Grupo cerrado' else 'Grupo abierto' end,
                         public.app_group_label(p_group_id));
  return jsonb_build_object('ok', true, 'locked', coalesce(p_locked, false));
end $$;

-- Carga un grupo ya armado. Todo o nada: si una fila falla, no se carga nada
-- y el error dice qué fila (IMPORT_ROW con detalle "fila:código").
create or replace function public.app_admin_import_group(
  p_token_hash text, p_topic_id text, p_group_number int, p_members jsonb, p_locked boolean default true)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_ceds     text[];
  v_topic    record;
  v_gid      text;
  v_row      jsonb;
  v_i        int := 0;
  v_student  public.students;
  v_current  text;
  v_created  jsonb := '[]'::jsonb;
  v_existing jsonb := '[]'::jsonb;
  v_moved    jsonb := '[]'::jsonb;
  v_label    text;
  v_from     text;
begin
  perform public.app_admin_assert(p_token_hash);

  if p_members is null or jsonb_typeof(p_members) <> 'array'
     or jsonb_array_length(p_members) not between 1 and 12 then
    perform public.app_raise('IMPORT_SIZE');
  end if;
  if p_group_number is not null and p_group_number not between 1 and 99 then
    perform public.app_raise('INVALID_INPUT');
  end if;

  select array_agg(public.app_norm_cedula(e->>'national_id')) into v_ceds
  from jsonb_array_elements(p_members) e;
  if array_position(v_ceds, null) is not null then
    perform public.app_raise('INVALID_NATIONAL_ID');
  end if;
  if (select count(distinct c) from unnest(v_ceds) c) <> cardinality(v_ceds) then
    perform public.app_raise('IMPORT_DUPLICATE');
  end if;

  -- Orden de bloqueo igual al resto: estudiantes -> tema -> grupos
  perform 1 from public.students s where s.national_id = any (v_ceds) order by s.national_id for update;

  select t.id, t.number into v_topic from public.topics t where t.id::text = p_topic_id for update;
  if not found then
    perform public.app_raise('TOPIC_NOT_FOUND');
  end if;

  if p_group_number is null then
    v_gid := public.app_new_group(p_topic_id);
  else
    select g.id::text into v_gid from public.groups g
    where g.topic_id = v_topic.id and g.group_number = p_group_number
    for update;
    if v_gid is null then
      insert into public.groups (topic_id, group_number) values (v_topic.id, p_group_number)
      returning id::text into v_gid;
    end if;
  end if;
  v_label := public.app_group_label(v_gid);

  for v_row in select value from jsonb_array_elements(p_members) loop
    v_i := v_i + 1;
    v_student := null;
    begin
      select * into v_student from public.students
      where national_id = public.app_norm_cedula(v_row->>'national_id');

      if v_student.id is null then
        insert into public.students (full_name, national_id, phone)
        values (v_row->>'full_name', v_row->>'national_id', nullif(btrim(coalesce(v_row->>'phone', '')), ''))
        returning * into v_student;
        v_created := v_created || to_jsonb(v_student.full_name);
      else
        v_existing := v_existing || to_jsonb(v_student.full_name);
      end if;

      v_current := public.app_current_group(v_student.id::text);
      if v_current is distinct from v_gid then
        v_from := public.app_group_label(v_current);   -- antes de mover: el grupo viejo puede borrarse
        perform public.app_move_student(v_student.id::text, v_gid);
        if v_current is not null then
          v_moved := v_moved || jsonb_build_object('name', v_student.full_name, 'from', v_from);
        end if;
        perform public.app_log('admin', v_student.id::text, 'Cargado en grupo',
                               concat_ws(' → ', v_from, v_label));
      end if;
    exception
      when sqlstate 'P0001' then
        raise exception using errcode = 'P0001', message = 'IMPORT_ROW', detail = v_i || ':' || sqlerrm;
      when unique_violation then
        raise exception using errcode = 'P0001', message = 'IMPORT_ROW', detail = v_i || ':NATIONAL_ID_TAKEN';
    end;
  end loop;

  update public.groups g set locked = coalesce(p_locked, false) where g.id::text = v_gid;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_gid,
    'topic_number', v_topic.number,
    'group_number', (select g.group_number from public.groups g where g.id::text = v_gid),
    'count', (select count(*) from public.group_memberships m where m.group_id::text = v_gid),
    'locked', coalesce(p_locked, false),
    'created', v_created,
    'existing', v_existing,
    'moved', v_moved);
end $$;

-- ---------------------------------------------------------------------
-- 7. Se quita el PIN guardado (ya no se usa)
-- ---------------------------------------------------------------------
alter table public.students drop column if exists pin_hash;

-- ---------------------------------------------------------------------
-- 8. Seguridad (igual que la migración 1)
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  alter table public.activity_log enable row level security;
  revoke all on table public.activity_log from public, anon, authenticated;
  grant select, insert, update, delete on table public.activity_log to service_role;

  for r in select policyname from pg_policies where schemaname = 'public' and tablename = 'activity_log' loop
    execute format('drop policy %I on public.activity_log', r.policyname);
  end loop;

  for r in select p.oid::regprocedure as f from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
  end loop;
end $$;

commit;

notify pgrst, 'reload schema';
