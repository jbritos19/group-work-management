# Grupos del trabajo práctico — guía

App web para que ~120 estudiantes vean los 14 temas y armen grupos de 8 a 12 integrantes, más un panel para el administrador.

- **App de estudiantes:** https://grupostrabajopractico.netlify.app
- **Panel (no compartir):** https://grupostrabajopractico.netlify.app/admin.html
- **Proyecto Supabase:** `trabajo-practico-grupos` (`bgtlfjksjjdrdcfeyutv`)

## Contenido

```
grupos-tp/
├── LEEME.md
├── supabase/
│   ├── 00_auditoria_solo_lectura.sql              ← revisión (no cambia nada)
│   ├── migrations/
│   │   ├── 20260916120000_grupos_seguros.sql      ← versión 1 (ya aplicada)
│   │   └── 20260918120000_sin_pin_carga_grupos.sql ← versión 2 (aplicar)
│   ├── 99_revertir_migracion_OPCIONAL.sql         ← solo para deshacer
│   └── functions/group-app/index.ts               ← código de la función
└── web/                                           ← se sube a Netlify
    ├── index.html   ← app de estudiantes
    ├── admin.html   ← panel del administrador
    └── config.js    ← dirección de la función (sin claves)
```

---

## Actualizar a la versión 2 (entrada solo con cédula y carga de grupos)

Ya hiciste la versión 1. Estos son los únicos 3 pasos nuevos.

### 1. Base de datos

1. Abrí `supabase/migrations/20260918120000_sin_pin_carga_grupos.sql` con el Bloc de notas → **Ctrl + A** → **Ctrl + C**.
2. Supabase → **SQL Editor** → **New query** → **Ctrl + V** → **Run**.
3. Debe decir *Success*. Si Supabase avisa que hay operaciones destructivas, confirmá: solo quita el PIN y las funciones viejas, no borra estudiantes ni grupos.

### 2. Función

1. Abrí `supabase/functions/group-app/index.ts` con el Bloc de notas → **Ctrl + A** → **Ctrl + C**.
2. Supabase → **Edge Functions** → **group-app** → **Code** → clic en el código → **Ctrl + A** → **Ctrl + V** → **Deploy**.
3. No cambies nada más: los secretos y la verificación de JWT desactivada siguen igual.

### 3. Página web

1. Descomprimí el `.zip` (clic derecho → **Extraer todo**). No se puede arrastrar desde adentro del `.zip`.
2. Netlify → tu sitio **grupostrabajopractico** → pestaña **Deploys**.
3. Arrastrá al recuadro de abajo la **carpeta `web` entera** (la que contiene `index.html`, `admin.html` y `config.js`).
   - No arrastres archivos sueltos ni la carpeta `grupos-tp`: si subís solo `admin.html`, el panel queda como página principal y falta `config.js`.
4. Esperá a que diga *Published*. La dirección no cambia.
5. Comprobá: la dirección principal muestra la app de estudiantes y `/admin.html` muestra el panel.

### Probar

1. **Como estudiante:** en el celular abrí la app → **Entrar con mi cédula** → escribí una cédula de prueba → te pide nombre y teléfono → **Registrarme**.
2. **Como administrador:** en el panel → **Grupos** → **Cargar grupo ya armado** → pegá una lista de prueba → **Revisar lista** → **Cargar**.
3. **Revisar los movimientos:** en **Historial** tienen que aparecer ambos.
4. **Limpiar:** en **Estudiantes**, eliminá los registros de prueba.

---

## Cómo lo usan los estudiantes

1. Tocan **Entrar con mi cédula** y escriben su número (con o sin puntos).
2. Si ya estaban registrados (o los cargaste vos), entran directo.
3. Si no, la app les pide **nombre y teléfono** y quedan registrados.
4. Ven los 14 temas y, dentro de cada uno, los grupos con sus integrantes. Desde ahí pueden **unirse**, **crear un grupo**, **abandonar** o **cambiarse**.
5. Arriba siempre ven: **"Actualmente estás en: Tema X — Grupo X"** y **"Entraste como …  ¿No sos vos? Salir"**.
6. Si los cargaste sin teléfono, la app les pide que lo completen.
7. Desde el inicio y desde cada tema pueden abrir **Consignas del trabajo práctico**: estructura del informe (portada, introducción, desarrollo teórico-doctrinario, análisis de caso nacional obligatorio, conclusiones y propuestas, bibliografía) y requisitos de forma (8 a 12 integrantes, 10 a 15 páginas, Arial o Times New Roman 12, interlineado 1,5, texto justificado, PDF, 10 puntos).

**Colores:** 1–7 integrantes **Buscando integrantes** (verde) · 8–11 **En formación** (amarillo) · 12 **Completo** (rojo).

## Cómo usás el panel

Entrás a `admin.html` con tu contraseña (el secreto `ADMIN_PASSWORD`).

- **Resumen:** cuántos registrados, cuántos sin grupo, grupos completos o incompletos, detalle por tema.
- **Estudiantes:** buscar por nombre, cédula o teléfono y filtrar (sin grupo, con grupo, sin teléfono). Desde cada estudiante:
  - **Mover** o **Asignar grupo**;
  - **Quitar del grupo**;
  - **Corregir** nombre, cédula o teléfono;
  - ver su **Historial**;
  - **Eliminar** el registro.
- **Grupos:**
  - **Cargar grupo ya armado** (ver abajo);
  - **+ Grupo vacío**;
  - **Cerrar / Abrir grupo**;
  - **Eliminar grupo** (sus integrantes quedan sin grupo);
  - filtros cerrados / incompletos / en formación / completos.
- **Historial:** todos los movimientos (quién se unió, se cambió, abandonó, qué hiciste vos), con fecha y hora. Se puede filtrar por nombre.
- **Exportar:**
  - abrir o cerrar la inscripción y los cambios de grupo;
  - descargar CSV para Excel (grupos, todos los estudiantes, sin grupo);
  - copiar la lista para WhatsApp, solo con nombres.

### Cargar grupos que ya te pasaron

1. **Grupos** → **Cargar grupo ya armado** (o **Cargar grupo** dentro de un tema).
2. Elegí el **tema**.
3. **Número de grupo:** dejalo vacío para usar el siguiente libre. Si ponés un número que ya existe, los integrantes se agregan a ese grupo.
4. Pegá la lista, **un integrante por línea**. Sirven todas estas formas:
   ```
   Juan Pérez, 1.234.567, 0981 123 456
   María Gómez; 2345678
   3. Carlos Duarte 3.456.789 0982 333 444
   ```
   También podés copiar columnas desde Excel (nombre, cédula, teléfono). El teléfono es opcional.
5. **Cerrar el grupo** viene marcado: así nadie puede salir ni sumarse sin vos. Podés abrirlo después.
6. Tocá **Revisar lista**. Vas a ver cada fila con su situación:
   - **Nuevo:** se registra.
   - **Ya registrado como …:** se usa su registro (no se cambia su nombre ni teléfono) y, si estaba en otro grupo, se lo mueve.
   - **En rojo:** hay que corregir esa fila (falta la cédula, nombre incompleto, cédula repetida, etc.).
7. Si todo está bien, el botón pasa a **Cargar N integrantes**. Tocalo para confirmar.
8. La carga es **todo o nada**: si algo falla, no se carga nada y el mensaje dice en qué fila está el problema. Nunca se supera el máximo de 12.

---

## Seguridad: qué cambió y qué tener en cuenta

- **Los estudiantes entran solo con la cédula.** Es más simple, pero cualquiera que conozca la cédula de un compañero puede entrar como él y cambiarlo de grupo. Para eso están:
  - **Grupos cerrados:** nadie puede sacar ni meter gente en un grupo cerrado, salvo vos.
  - **Historial:** si alguien dice "yo no me cambié", ahí ves qué pasó y cuándo, y lo corregís con **Mover**.
  - **"¿No sos vos? Salir":** si alguien escribe mal su cédula y entra como otra persona, ve el nombre y puede salir.
  - **Recomendación:** cuando un grupo esté completo o confirmado, **cerralo**. Al final, cerrá los **cambios de grupo** para todos (pestaña Exportar).
- **Privacidad:** la cédula y el teléfono **solo los ve el administrador**. La app de estudiantes solo recibe nombres, temas, grupos, cantidades y estados. Sin entrar, ni siquiera se ven los nombres.
- **El panel sigue protegido con contraseña.** La contraseña vive solo en Supabase (secreto `ADMIN_PASSWORD`), nunca en la página. Tras 5 intentos fallidos desde un lugar, o 20 en total, el ingreso se bloquea 15 minutos.
- **La base de datos está cerrada.** Nadie puede leerla ni modificarla desde afuera, ni siquiera con la clave pública del proyecto. Todo pasa por la función `group-app`.
- **El último lugar no se duplica.** Si dos personas quieren el lugar 12 al mismo tiempo, entra una sola; la otra ve "grupo completo".
- **Actualización:** la app se refresca sola cada 6 segundos (el panel, cada 15).

---

## Detalle técnico (versión 2)

**Qué cambia la migración 2:**

| Qué | Cambio |
|---|---|
| `students.pin_hash` | Se elimina (ya no se usa PIN). |
| `students.phone` | Pasa a ser opcional (para cargados por el admin sin teléfono). Cuando se escribe, se valida y normaliza igual que antes. |
| `groups.locked` | Columna nueva (`boolean`, por defecto `false`). |
| `activity_log` | Tabla nueva: `id` (identidad), `created_at`, `actor` (`estudiante`/`admin`), `student_id` (FK a `students`, `ON DELETE SET NULL`), `student_name`, `action`, `detail`. Índices por fecha y por estudiante. RLS activado, sin políticas, solo `service_role`. |
| Funciones eliminadas | `app_register` (versión con PIN), `app_login`, `app_claim_pin`, `app_change_pin`, `app_admin_reset_pin`, `app_admin_unlock_student`, `app_login_blocked`, `app_pin_is_valid`. |
| Funciones nuevas | `app_enter`, `app_register` (sin PIN), `app_student_can_change`, `app_admin_import_group`, `app_admin_set_group_lock`, `app_log`, `app_group_label`, `app_current_group`, `app_ip_blocked`. |
| Funciones actualizadas | `app_state`, `app_join_group`, `app_create_group`, `app_leave_group`, `app_update_profile`, `app_admin_state` y las demás `app_admin_*` (ahora registran en el historial). |
| Permisos | Igual que antes: ninguna función ni tabla accesible por `anon`/`authenticated`. |

**Acciones de la función `group-app`:**

- **Estudiantes:** `state`, `enter`, `register`, `logout`, `join_group`, `create_group`, `leave_group`, `update_profile`.
- **Administrador:** `admin_login`, `admin_logout`, `admin_state`, `admin_move_student`, `admin_remove_from_group`, `admin_update_student`, `admin_delete_student`, `admin_create_group`, `admin_delete_group`, `admin_set_group_lock`, `admin_import_group`, `admin_set_settings`.

**Límites:**

- Hasta 300 intentos de entrada con cédulas inexistentes y 300 registros cada 10–15 minutos desde una misma red. Es un límite alto a propósito, porque toda la facultad puede compartir el mismo wifi.
- Sesiones de estudiantes: 30 días. Sesiones del administrador: 12 horas.

**Deshacer:** `99_revertir_migracion_OPCIONAL.sql` quita funciones, triggers y tablas nuevas. Conserva estudiantes, grupos, temas y membresías, y no reabre el acceso público. Probado: después se pueden volver a aplicar las dos migraciones.

## Pruebas realizadas (versión 2)

Se hicieron en un entorno local con una **réplica exacta de tu base** (según la auditoría): PostgreSQL + PostgREST + la función real + Chrome.

| Conjunto | Resultado |
|---|---|
| Base de datos (réplica con ids `bigint`) | 69/69 |
| Base de datos (variante con ids `uuid`) | 69/69 |
| API por HTTP | 31/31 |
| Navegador: app del estudiante (celular) y panel | 49/49 |
| Migración 2 aplicada dos veces, sobre base con datos y vacía; reversión y reaplicación | OK |

Incluye:

- 19 personas a la vez por el último lugar: entra 1.
- Una carga del admin compitiendo con 10 estudiantes por el mismo grupo: nunca pasa de 12 y no hay bloqueos.
- Una carga con una fila errónea no carga nada e indica la fila.
- Los grupos cerrados no se pueden abandonar ni ocupar desde la app.
- Con la clave pública no se puede leer nada.
- Ninguna respuesta al estudiante contiene cédulas ni teléfonos.

Lo que no puedo probar desde acá es tu proyecto real. Por eso, después de actualizar, hacé la prueba corta de arriba.
