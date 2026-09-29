-- =====================================================================
-- REVERSIÓN OPCIONAL de las migraciones 20260916120000_grupos_seguros.sql
-- y 20260918120000_sin_pin_carga_grupos.sql
-- Úsalo SOLO si necesitás deshacer la migración.
--
-- Qué hace:
--   * Quita los triggers y las funciones app_* creadas por la migración.
--   * Borra las tablas nuevas: app_settings, student_sessions,
--     admin_sessions, auth_events y activity_log (se pierden sesiones,
--     bloqueos y el historial de movimientos).
--   * NO borra estudiantes, grupos, temas ni membresías.
--   * Deja la columna groups.locked (no molesta; ver bloque comentado).
--   * NO vuelve a abrir las tablas a anon/authenticated: RLS queda activado
--     y sin políticas. Las políticas anteriores figuran en la auditoría que
--     guardaste antes de migrar, por si necesitás recrear alguna.
-- =====================================================================
begin;

drop trigger if exists app_students_normalize  on public.students;
drop trigger if exists app_membership_capacity on public.group_memberships;
drop trigger if exists app_membership_cleanup  on public.group_memberships;

do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f
           from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.proname like 'app\_%'
  loop
    execute format('drop function if exists %s cascade', r.f);
    raise notice 'Función eliminada: %', r.f;
  end loop;
end $$;

drop table if exists public.student_sessions;
drop table if exists public.admin_sessions;
drop table if exists public.auth_events;
drop table if exists public.app_settings;
drop table if exists public.activity_log;

-- Si también querés quitar la marca de grupo cerrado, descomentá la línea:
-- alter table public.groups drop column if exists locked;

commit;
notify pgrst, 'reload schema';
