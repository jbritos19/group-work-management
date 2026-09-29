// Única configuración del frontend. No contiene claves ni contraseñas:
// toda la seguridad vive en la Edge Function y en la base de datos.
window.APP_CONFIG = {
  FUNCTION_URL: "https://bgtlfjksjjdrdcfeyutv.supabase.co/functions/v1/group-app",
  POLL_SECONDS: 6,        // cada cuánto se actualizan los grupos (pestaña visible)
  ADMIN_POLL_SECONDS: 15, // idem para el panel administrativo
};
