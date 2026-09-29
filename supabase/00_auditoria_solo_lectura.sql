-- =====================================================================
-- AUDITORÍA (SOLO LECTURA) — trabajo-practico-grupos
-- No modifica nada. Pegalo en Supabase > SQL Editor > Run.
-- Devuelve un único JSON con todo lo necesario para revisar el estado
-- actual antes de aplicar la migración.
-- =====================================================================
with
tbls as (
  select c.oid, c.relname
  from pg_class c
  where c.relnamespace = 'public'::regnamespace
    and c.relkind in ('r', 'p', 'v', 'm')
),
cols as (
  select c.relname as tabla,
         jsonb_agg(jsonb_build_object(
           'columna', a.attname,
           'tipo', format_type(a.atttypid, a.atttypmod),
           'not_null', a.attnotnull,
           'default', pg_get_expr(d.adbin, d.adrelid),
           'identity', nullif(a.attidentity, '')
         ) order by a.attnum) as columnas
  from tbls c
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
  group by c.relname
),
cons as (
  select jsonb_agg(jsonb_build_object(
           'tabla', conrelid::regclass::text,
           'nombre', conname,
           'tipo', contype,
           'definicion', pg_get_constraintdef(oid)) order by conrelid::regclass::text, conname) as v
  from pg_constraint
  where connamespace = 'public'::regnamespace
),
idx as (
  select jsonb_agg(jsonb_build_object('tabla', tablename, 'indice', indexname, 'def', indexdef)
                   order by tablename, indexname) as v
  from pg_indexes where schemaname = 'public'
),
rls as (
  select jsonb_agg(jsonb_build_object('tabla', relname, 'tipo', relkind,
                   'rls_activado', relrowsecurity, 'rls_forzado', relforcerowsecurity)
                   order by relname) as v
  from pg_class
  where relnamespace = 'public'::regnamespace and relkind in ('r', 'p', 'v', 'm')
),
pol as (
  select jsonb_agg(jsonb_build_object('tabla', tablename, 'politica', policyname,
                   'roles', roles, 'cmd', cmd, 'using', qual, 'check', with_check)
                   order by tablename, policyname) as v
  from pg_policies where schemaname = 'public'
),
grants as (
  select jsonb_agg(jsonb_build_object('tabla', table_name, 'rol', grantee, 'privilegio', privilege_type)
                   order by table_name, grantee, privilege_type) as v
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee in ('anon', 'authenticated', 'PUBLIC')
),
funcs as (
  select jsonb_agg(jsonb_build_object(
           'funcion', p.oid::regprocedure::text,
           'security_definer', p.prosecdef,
           'search_path', p.proconfig,
           'ejecutable_por_anon', has_function_privilege('anon', p.oid, 'EXECUTE'),
           'ejecutable_por_authenticated', has_function_privilege('authenticated', p.oid, 'EXECUTE'))
           order by p.proname) as v
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
),
views as (
  select jsonb_agg(jsonb_build_object('vista', viewname, 'definicion', definition)) as v
  from pg_views where schemaname = 'public'
),
trg as (
  select jsonb_agg(jsonb_build_object('tabla', tgrelid::regclass::text, 'trigger', tgname,
                   'def', pg_get_triggerdef(oid))) as v
  from pg_trigger
  where not tgisinternal and tgrelid in (select oid from tbls)
),
ext as (
  select jsonb_agg(jsonb_build_object('extension', e.extname, 'esquema', n.nspname, 'version', e.extversion)) as v
  from pg_extension e join pg_namespace n on n.oid = e.extnamespace
),
pub as (
  select jsonb_agg(jsonb_build_object('publicacion', pubname, 'tabla', schemaname || '.' || tablename)) as v
  from pg_publication_tables where pubname = 'supabase_realtime'
),
defpriv as (
  select jsonb_agg(jsonb_build_object('rol_creador', pg_get_userbyid(defaclrole),
                   'esquema', defaclnamespace::regnamespace::text,
                   'objeto', defaclobjtype, 'acl', defaclacl::text)) as v
  from pg_default_acl
),
datos as (
  select jsonb_build_object(
    'topics', (select count(*) from public.topics),
    'groups', (select count(*) from public.groups),
    'students', (select count(*) from public.students),
    'group_memberships', (select count(*) from public.group_memberships),
    'estudiantes_con_mas_de_un_grupo',
      (select count(*) from (select student_id from public.group_memberships
                             group by student_id having count(*) > 1) x),
    'grupos_con_mas_de_12',
      (select count(*) from (select group_id from public.group_memberships
                             group by group_id having count(*) > 12) x),
    'grupos_vacios',
      (select count(*) from public.groups g
       where not exists (select 1 from public.group_memberships m where m.group_id = g.id)),
    'membresias_huerfanas',
      (select count(*) from public.group_memberships m
       where not exists (select 1 from public.students s where s.id = m.student_id)
          or not exists (select 1 from public.groups g where g.id = m.group_id)),
    -- cédulas que quedarían duplicadas al quitar puntos/espacios/guiones
    'cedulas_duplicadas_al_normalizar',
      (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
         select upper(regexp_replace(national_id, '[^0-9A-Za-z]', '', 'g')) as cedula_normalizada,
                count(*) as cantidad
         from public.students
         group by 1 having count(*) > 1) x),
    'cedulas_con_formato', (select count(*) from public.students
                            where national_id !~ '^[0-9A-Z]+$'),
    'temas', (select jsonb_agg(jsonb_build_object('number', number, 'title', title) order by number)
              from public.topics)
  ) as v
)
select jsonb_pretty(jsonb_build_object(
  'columnas', (select jsonb_object_agg(tabla, columnas) from cols),
  'restricciones', (select v from cons),
  'indices', (select v from idx),
  'rls', (select v from rls),
  'politicas', (select v from pol),
  'privilegios_anon_authenticated', (select v from grants),
  'funciones_public', (select v from funcs),
  'vistas', (select v from views),
  'triggers', (select v from trg),
  'extensiones', (select v from ext),
  'realtime', (select v from pub),
  'privilegios_por_defecto', (select v from defpriv),
  'datos', (select v from datos)
)) as auditoria;
