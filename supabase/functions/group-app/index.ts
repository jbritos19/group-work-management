// =====================================================================
// Edge Function: group-app
// API única (POST JSON { action, ... }) para la app de grupos.
//
// Seguridad:
//  - Estudiantes: entran solo con su cédula. Reciben un token de sesión
//    aleatorio (32 bytes) en el header "x-session-token". En la base solo
//    se guarda su SHA-256.
//  - Administrador: contraseña en el secreto ADMIN_PASSWORD (nunca en el
//    frontend). Al validarla se emite un token en "x-admin-token".
//  - La base solo es accesible con la clave secreta (service_role) que
//    Supabase inyecta en esta función. El navegador nunca la ve.
//  - Ninguna respuesta pública contiene cédulas ni teléfonos.
//
// Secretos (Dashboard > Edge Functions > Secrets):
//  - ADMIN_PASSWORD   (obligatorio para el panel; mínimo 12 caracteres)
//  - ALLOWED_ORIGINS  (opcional; ej: "https://grupos-tp.netlify.app")
// SUPABASE_URL y las claves los provee Supabase automáticamente.
// =====================================================================

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
const SERVICE_KEY = pickServiceKey();
const ADMIN_PASSWORD = Deno.env.get("ADMIN_PASSWORD") ?? "";
const ALLOWED_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",").map((s) => s.trim().replace(/\/+$/, "")).filter(Boolean);

function pickServiceKey(): string {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const obj = JSON.parse(raw) as Record<string, string>;
      const key = obj.default ?? Object.values(obj)[0];
      if (key) return key;
    } catch { /* se usa la clave heredada */ }
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

// ---------------------------------------------------------------------
// Errores: código -> [HTTP, mensaje para el usuario]
// ---------------------------------------------------------------------
const ERRORS: Record<string, [number, string]> = {
  INVALID_INPUT: [400, "Revisá los datos ingresados."],
  INVALID_NAME: [400, "Escribí nombre y apellido (solo letras, mínimo dos palabras)."],
  INVALID_PHONE: [400, "El número de teléfono no es válido. Ejemplo: 0981 123 456."],
  INVALID_NATIONAL_ID: [400, "La cédula no es válida. Escribí solo los números."],
  NOT_REGISTERED: [404, "Todavía no estás registrado con esa cédula."],
  NOT_AUTHENTICATED: [401, "Tu sesión terminó. Volvé a entrar con tu cédula."],
  ADMIN_INVALID_PASSWORD: [401, "Contraseña incorrecta."],
  NATIONAL_ID_TAKEN: [409, "Esa cédula ya pertenece a otro estudiante."],
  GROUP_FULL: [409, "Ese grupo ya está completo (12 de 12). Elegí otro."],
  GROUP_LOCKED: [403, "Ese grupo está cerrado por el administrador."],
  GROUP_LOCKED_MINE: [403, "Tu grupo está cerrado por el administrador. Para cambiarte, hablá con él."],
  ALREADY_IN_GROUP: [409, "Ya estás en ese grupo."],
  NOT_IN_GROUP: [409, "No estás en ningún grupo."],
  GROUP_NOT_FOUND: [404, "Ese grupo ya no existe. La lista se actualizó."],
  TOPIC_NOT_FOUND: [404, "Ese tema no existe."],
  STUDENT_NOT_FOUND: [404, "Ese estudiante ya no existe."],
  IMPORT_SIZE: [400, "Cargá entre 1 y 12 integrantes."],
  IMPORT_DUPLICATE: [400, "Hay una cédula repetida en la lista."],
  IMPORT_ROW: [400, "Hay un error en la lista."],
  REGISTRATION_CLOSED: [403, "La inscripción está cerrada."],
  CHANGES_CLOSED: [403, "Los cambios de grupo están cerrados."],
  TOO_MANY_ATTEMPTS: [429, "Demasiados intentos. Esperá 15 minutos."],
  RATE_LIMITED: [429, "Demasiadas solicitudes. Esperá unos minutos."],
  UNKNOWN_ACTION: [400, "Acción desconocida."],
  METHOD_NOT_ALLOWED: [405, "Método no permitido."],
  PAYLOAD_TOO_LARGE: [413, "Solicitud demasiado grande."],
  ORIGIN_NOT_ALLOWED: [403, "Origen no permitido."],
  ADMIN_DISABLED: [503, "El panel no está configurado (falta el secreto ADMIN_PASSWORD)."],
  SERVER_MISCONFIGURED: [500, "La función no tiene acceso a la base de datos."],
  INTERNAL: [500, "Ocurrió un error. Intentá de nuevo."],
};

class AppError extends Error {
  constructor(public code: string, public userMessage?: string) {
    super(code);
  }
}

// ---------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------
function corsHeaders(req: Request): Record<string, string> {
  const origin = (req.headers.get("origin") ?? "").replace(/\/+$/, "");
  let allow = "*";
  if (ALLOWED_ORIGINS.length) allow = ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "authorization, apikey, content-type, x-client-info, x-session-token, x-admin-token",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

function json(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(req),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function errorResponse(req: Request, code: string, custom?: string): Response {
  const [status, message] = ERRORS[code] ?? ERRORS.INTERNAL;
  return json(req, status, { ok: false, error: { code: ERRORS[code] ? code : "INTERNAL", message: custom ?? message } });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function newToken(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return base64url(b);
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), (x) => x.toString(16).padStart(2, "0")).join("");
}

async function tokenHash(req: Request, header: string): Promise<string | null> {
  const t = req.headers.get(header);
  if (!t || !/^[A-Za-z0-9_-]{43}$/.test(t)) return null;
  return await sha256Hex(t);
}

async function safeEqual(a: string, b: string): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw", crypto.getRandomValues(new Uint8Array(32)),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const enc = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.sign("HMAC", key, enc.encode(a)),
    crypto.subtle.sign("HMAC", key, enc.encode(b)),
  ]);
  const ax = new Uint8Array(x), by = new Uint8Array(y);
  let diff = 0;
  for (let i = 0; i < ax.length; i++) diff |= ax[i] ^ by[i];
  return diff === 0;
}

function clientIp(req: Request): string | null {
  const v = req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-real-ip") ??
    req.headers.get("x-forwarded-for")?.split(",")[0];
  const ip = v?.trim();
  return ip && ip.length <= 64 ? ip : null;
}

// Validaciones rápidas (la base vuelve a validar todo)
function str(v: unknown, max: number): string {
  if (typeof v !== "string" || v.length > max) throw new AppError("INVALID_INPUT");
  return v;
}
function optStr(v: unknown, max: number): string | null {
  if (v === undefined || v === null || v === "") return null;
  return str(v, max);
}
function id(v: unknown): string {
  if (typeof v === "number" && Number.isSafeInteger(v)) return String(v);
  if (typeof v === "string" && /^[0-9A-Za-z-]{1,64}$/.test(v)) return v;
  throw new AppError("INVALID_INPUT");
}
function members(v: unknown): Array<Record<string, string>> {
  if (!Array.isArray(v) || v.length < 1 || v.length > 12) throw new AppError("IMPORT_SIZE");
  return v.map((m) => {
    if (!m || typeof m !== "object") throw new AppError("INVALID_INPUT");
    const o = m as Record<string, unknown>;
    return {
      full_name: str(o.full_name, 120),
      national_id: str(o.national_id, 30),
      phone: optStr(o.phone, 30) ?? "",
    };
  });
}
function optInt(v: unknown, min: number, max: number): number | null {
  if (v === undefined || v === null || v === "") return null;
  const n = typeof v === "string" ? Number(v) : v;
  if (typeof n !== "number" || !Number.isInteger(n) || n < min || n > max) throw new AppError("INVALID_INPUT");
  return n;
}
function name(v: unknown): string {
  const n = str(v, 120).normalize("NFC").replace(/\s+/g, " ").trim();
  if (n.length < 5 || n.length > 80 || !n.includes(" ") || !/^[\p{L}\p{M}' .-]+$/u.test(n)) {
    throw new AppError("INVALID_NAME");
  }
  return n;
}
function optBool(v: unknown): boolean | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "boolean") throw new AppError("INVALID_INPUT");
  return v;
}

// ---------------------------------------------------------------------
// Llamada a funciones RPC de Postgres (vía la API REST del proyecto)
// ---------------------------------------------------------------------
async function rpc<T = any>(fn: string, args: Record<string, unknown>, attempt = 0): Promise<T> {
  if (!SUPABASE_URL || !SERVICE_KEY) throw new AppError("SERVER_MISCONFIGURED");
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "apikey": SERVICE_KEY,
  };
  // Las claves heredadas son JWT y van también en Authorization.
  // Las nuevas (sb_secret_...) solo van en apikey.
  if (SERVICE_KEY.startsWith("eyJ")) headers["Authorization"] = `Bearer ${SERVICE_KEY}`;

  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (res.ok) return (text ? JSON.parse(text) : null) as T;

  let err: { code?: string; message?: string; details?: string } = {};
  try { err = JSON.parse(text); } catch { /* respuesta no JSON */ }

  // Conflictos transitorios de concurrencia: reintento corto
  if ((err.code === "40P01" || err.code === "40001") && attempt < 3) {
    await sleep(40 + Math.random() * 120);
    return rpc<T>(fn, args, attempt + 1);
  }
  if (err.code === "P0001" && err.message === "IMPORT_ROW") {
    // detalle "fila:CÓDIGO"
    const m = /^(\d+):([A-Z_]+)$/.exec(err.details ?? "");
    const inner = m && ERRORS[m[2]] ? ERRORS[m[2]][1] : ERRORS.INVALID_INPUT[1];
    throw new AppError("IMPORT_ROW", m ? `Fila ${m[1]}: ${inner}` : ERRORS.IMPORT_ROW[1]);
  }
  if (err.code === "P0001" && err.message && ERRORS[err.message]) {
    throw new AppError(err.message);
  }
  // No se registran los argumentos (contienen cédulas y teléfonos)
  console.error("rpc_error", fn, res.status, err.code ?? "", (err.message ?? text).slice(0, 300));
  throw new AppError("INTERNAL");
}

type Ctx = {
  req: Request;
  body: Record<string, unknown>;
  ip: string | null;
  session: string | null; // hash del token del estudiante
  admin: string | null;   // hash del token de admin
};

function needSession(c: Ctx): string {
  if (!c.session) throw new AppError("NOT_AUTHENTICATED");
  return c.session;
}
function needAdmin(c: Ctx): string {
  if (!c.admin) throw new AppError("NOT_AUTHENTICATED");
  return c.admin;
}

// Respuestas de login/registro que devuelven { ok:false, error } sin excepción
function unwrap<T extends { ok?: boolean; error?: string }>(r: T): T {
  if (r && r.ok === false) throw new AppError(r.error ?? "INTERNAL");
  return r;
}

async function startSession(fn: string, args: Record<string, unknown>) {
  const token = newToken();
  const r = unwrap(await rpc(fn, { ...args, p_token_hash: await sha256Hex(token) }));
  return { token, expires_at: r.expires_at, full_name: r.full_name, existed: r.existed ?? true };
}

// ---------------------------------------------------------------------
// Acciones
// ---------------------------------------------------------------------
const actions: Record<string, (c: Ctx) => Promise<unknown>> = {
  // ---- públicas / estudiantes ----
  state: (c) => rpc("app_state", { p_token_hash: c.session }),

  // Entrar solo con la cédula
  enter: (c) =>
    startSession("app_enter", {
      p_national_id: str(c.body.national_id, 30),
      p_ip: c.ip,
    }),

  // Registro (si la cédula ya existe, simplemente entra)
  register: (c) =>
    startSession("app_register", {
      p_full_name: name(c.body.full_name),
      p_national_id: str(c.body.national_id, 30),
      p_phone: str(c.body.phone, 30),
      p_ip: c.ip,
    }),

  logout: async (c) => c.session ? rpc("app_logout", { p_token_hash: c.session }) : { ok: true },

  join_group: (c) =>
    rpc("app_join_group", { p_token_hash: needSession(c), p_group_id: id(c.body.group_id) }),

  create_group: (c) =>
    rpc("app_create_group", { p_token_hash: needSession(c), p_topic_id: id(c.body.topic_id) }),

  leave_group: (c) => rpc("app_leave_group", { p_token_hash: needSession(c) }),

  update_profile: (c) => {
    const full = optStr(c.body.full_name, 120);
    return rpc("app_update_profile", {
      p_token_hash: needSession(c),
      p_full_name: full === null ? null : name(full),
      p_phone: optStr(c.body.phone, 30),
    });
  },

  // ---- administrador ----
  admin_login: async (c) => {
    if (ADMIN_PASSWORD.length < 12) throw new AppError("ADMIN_DISABLED");
    const password = str(c.body.password, 200);
    const allowed = await rpc<boolean>("app_admin_login_allowed", { p_ip: c.ip });
    if (!allowed) throw new AppError("TOO_MANY_ATTEMPTS");
    if (!(await safeEqual(password, ADMIN_PASSWORD))) {
      await rpc("app_admin_login_failed", { p_ip: c.ip });
      await sleep(400 + Math.random() * 400);
      throw new AppError("ADMIN_INVALID_PASSWORD");
    }
    const token = newToken();
    const r = await rpc("app_admin_create_session", { p_token_hash: await sha256Hex(token), p_ip: c.ip });
    return { token, expires_at: r.expires_at };
  },

  admin_logout: async (c) => c.admin ? rpc("app_admin_logout", { p_token_hash: c.admin }) : { ok: true },

  admin_state: (c) => rpc("app_admin_state", { p_token_hash: needAdmin(c) }),

  admin_move_student: (c) =>
    rpc("app_admin_move_student", {
      p_token_hash: needAdmin(c),
      p_student_id: id(c.body.student_id),
      p_group_id: id(c.body.group_id),
    }),

  admin_remove_from_group: (c) =>
    rpc("app_admin_remove_from_group", { p_token_hash: needAdmin(c), p_student_id: id(c.body.student_id) }),

  admin_update_student: (c) => {
    const full = optStr(c.body.full_name, 120);
    return rpc("app_admin_update_student", {
      p_token_hash: needAdmin(c),
      p_student_id: id(c.body.student_id),
      p_full_name: full === null ? null : name(full),
      p_national_id: optStr(c.body.national_id, 30),
      p_phone: optStr(c.body.phone, 30),
    });
  },

  admin_delete_student: (c) =>
    rpc("app_admin_delete_student", { p_token_hash: needAdmin(c), p_student_id: id(c.body.student_id) }),

  admin_create_group: (c) =>
    rpc("app_admin_create_group", { p_token_hash: needAdmin(c), p_topic_id: id(c.body.topic_id) }),

  admin_delete_group: (c) =>
    rpc("app_admin_delete_group", { p_token_hash: needAdmin(c), p_group_id: id(c.body.group_id) }),

  admin_set_group_lock: (c) =>
    rpc("app_admin_set_group_lock", {
      p_token_hash: needAdmin(c),
      p_group_id: id(c.body.group_id),
      p_locked: optBool(c.body.locked) ?? false,
    }),

  admin_import_group: (c) =>
    rpc("app_admin_import_group", {
      p_token_hash: needAdmin(c),
      p_topic_id: id(c.body.topic_id),
      p_group_number: optInt(c.body.group_number, 1, 99),
      p_members: members(c.body.members),
      p_locked: optBool(c.body.locked) ?? true,
    }),

  admin_set_settings: (c) =>
    rpc("app_admin_set_settings", {
      p_token_hash: needAdmin(c),
      p_registration_open: optBool(c.body.registration_open),
      p_group_changes_open: optBool(c.body.group_changes_open),
    }),
};

// ---------------------------------------------------------------------
// Servidor
// ---------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req) });
  if (req.method !== "POST") return errorResponse(req, "METHOD_NOT_ALLOWED");

  const origin = (req.headers.get("origin") ?? "").replace(/\/+$/, "");
  if (ALLOWED_ORIGINS.length && origin && !ALLOWED_ORIGINS.includes(origin)) {
    return errorResponse(req, "ORIGIN_NOT_ALLOWED");
  }

  try {
    const raw = await req.text();
    if (raw.length > 16000) return errorResponse(req, "PAYLOAD_TOO_LARGE");
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(raw || "{}");
    } catch {
      return errorResponse(req, "INVALID_INPUT");
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) return errorResponse(req, "INVALID_INPUT");

    const action = typeof body.action === "string" ? body.action : "";
    const handler = Object.hasOwn(actions, action) ? actions[action] : undefined;
    if (!handler) return errorResponse(req, "UNKNOWN_ACTION");

    const ctx: Ctx = {
      req,
      body,
      ip: clientIp(req),
      session: await tokenHash(req, "x-session-token"),
      admin: action.startsWith("admin_") ? await tokenHash(req, "x-admin-token") : null,
    };
    const data = await handler(ctx);
    return json(req, 200, { ok: true, data });
  } catch (e) {
    if (e instanceof AppError) return errorResponse(req, e.code, e.userMessage);
    console.error("unhandled", e instanceof Error ? e.message : String(e));
    return errorResponse(req, "INTERNAL");
  }
});
