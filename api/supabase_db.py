"""
supabase_db.py
--------------
Mirrors every workflow step into the Supabase PostgreSQL database.

All public functions are async (background thread) so Supabase network
latency NEVER slows down the main API response to the Flutter app.
If Supabase is unreachable, errors are printed but the app keeps working.

Workflow covered:
  Officer creates request        → requests  +  request_status_logs
  Admin forwards to TSP          → admin_forward_requests  +  request_status_logs
  TSP submits response           → tsp_responses  +  request_status_logs
  Admin forwards response        → admin_forward_responses  +  officer_received_responses
  Request status changes         → request_status_logs (audit trail)
"""

import json
import os
import threading
import uuid as _uuid_mod

# ── Supabase connection config ───────────────────────────────────────────────
_DB_CONFIG = dict(
    host=os.environ.get('SUPABASE_DB_HOST', "db.sargsmajubzlwtwvgyeq.supabase.co"),
    port=int(os.environ.get('SUPABASE_DB_PORT', "6543")),
    dbname=os.environ.get('SUPABASE_DB_NAME', "postgres"),
    user=os.environ.get('SUPABASE_DB_USER', "postgres"),
    password=os.environ.get('SUPABASE_DB_PASSWORD', "smsforward@system"),
    sslmode="require",
    connect_timeout=10,
)

# Deterministic UUID namespace (uuid5)
_NS = _uuid_mod.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")


def _conn():
    import psycopg2
    return psycopg2.connect(**_DB_CONFIG)


def _uid(prefix: str, django_id) -> str:
    """Return a deterministic UUID for a given Django object."""
    return str(_uuid_mod.uuid5(_NS, f"{prefix}:{django_id}"))


# ── Role mapping ─────────────────────────────────────────────────────────────
_ROLE = {"ADMIN": "Admin", "OFFICER": "Officer", "TSP": "TSP"}

# Django status  →  Supabase status
_STATUS = {
    "PENDING":       "Submitted",
    "APPROVED":      "Sent_To_Admin",
    "REJECTED":      "Submitted",
    "FORWARDED":     "Forwarded_To_TSP",
    "PROCESSING":    "Forwarded_To_TSP",
    "TSP_RESPONDED": "Response_Received_From_TSP",
    "COMPLETED":     "Forwarded_To_Officer",
    "CLOSED":        "Completed",
}


def _ensure_dummy_user(uid: str, name: str, role: str):
    """Ensure a placeholder/dummy user exists in public.users to satisfy FK constraints."""
    sql = """
        INSERT INTO public.users
            (id, full_name, email, mobile_number, role, is_active, created_at, updated_at)
        VALUES (%s, %s, %s, '', %s, TRUE, NOW(), NOW())
        ON CONFLICT (id) DO NOTHING
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (uid, name, f"{uid}@system.local", role))
    finally:
        c.close()


def _ensure_dummy_tsp_response(django_req, resp_uid: str):
    """Ensure a dummy response exists in public.tsp_responses to satisfy FK constraints."""
    save_request(django_req)
    dummy_tsp_uid = _uid("user", 0)
    _ensure_dummy_user(dummy_tsp_uid, "System TSP", "TSP")
    
    req_uid = _uid("request", django_req.id)
    sql = """
        INSERT INTO public.tsp_responses
            (id, request_id, tsp_id, response_message, response_data, response_date, created_at)
        VALUES (%s, %s, %s, 'No response content', '{}'::jsonb, CURRENT_DATE, NOW())
        ON CONFLICT (id) DO NOTHING
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (resp_uid, req_uid, dummy_tsp_uid))
    finally:
        c.close()


# ============================================================
# 1. USER SYNC
# ============================================================
def sync_user(django_user) -> str:
    """Upsert a Django User into Supabase users table. Returns the UUID."""
    if not django_user:
        dummy_uid = _uid("user", 0)
        _ensure_dummy_user(dummy_uid, "System User", "Officer")
        return dummy_uid

    uid = _uid("user", django_user.id)
    full_name = (
        f"{django_user.first_name} {django_user.last_name}".strip()
        or django_user.username
    )
    email = django_user.email or f"{django_user.username}@local"
    role = _ROLE.get(str(django_user.role), "Officer")
    last_login = django_user.last_login

    sql = """
        INSERT INTO public.users
            (id, full_name, email, mobile_number, role, is_active, last_login, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, NOW(), NOW())
        ON CONFLICT (id) DO UPDATE SET
            full_name    = EXCLUDED.full_name,
            email        = EXCLUDED.email,
            role         = EXCLUDED.role,
            is_active    = EXCLUDED.is_active,
            last_login   = EXCLUDED.last_login,
            updated_at   = NOW()
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (uid, full_name, email, "", role, django_user.is_active, last_login))
    finally:
        c.close()
    return uid


# ============================================================
# 2. REQUEST
# ============================================================
def save_request(django_req) -> str:
    """Upsert a Request into Supabase requests table. Returns the UUID."""
    if not django_req:
        return ""

    # Ensure foreign key dependencies exist
    if django_req.officer:
        sync_user(django_req.officer)
    else:
        dummy_off = _uid("user", 0)
        _ensure_dummy_user(dummy_off, "System Officer", "Officer")

    req_uid   = _uid("request", django_req.id)
    off_uid   = _uid("user", django_req.officer_id) if django_req.officer_id else _uid("user", 0)
    supa_st   = _STATUS.get(str(django_req.status), "Submitted")
    title     = django_req.subject or f"Request #{django_req.id} – {django_req.mobile_number}"
    desc      = django_req.reason or django_req.remarks or ""
    req_data  = json.dumps({
        "mobile_number": django_req.mobile_number,
        "tsp":           django_req.tsp.name if django_req.tsp else "",
        "station_name":  django_req.station_name,
        "cr_no":         django_req.cr_no,
        "location":      django_req.location,
        "ticket_id":     django_req.ticket_id,
        "admin_remarks": django_req.admin_remarks,
        "response":      django_req.response,
    })

    sql = """
        INSERT INTO public.requests
            (id, officer_id, request_title, request_description,
             request_data, status, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s::jsonb, %s, %s, NOW())
        ON CONFLICT (id) DO UPDATE SET
            request_title       = EXCLUDED.request_title,
            request_description = EXCLUDED.request_description,
            request_data        = EXCLUDED.request_data,
            status              = EXCLUDED.status,
            updated_at          = NOW()
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (
                    req_uid, off_uid, title, desc, req_data,
                    supa_st, django_req.created_at,
                ))
    finally:
        c.close()
    return req_uid


# ============================================================
# 3. ADMIN → TSP FORWARD
# ============================================================
def save_admin_forward_request(django_req, admin_user, tsp_user=None, message="") -> str:
    """
    Upsert a row in admin_forward_requests.
    One row per (request, admin) pair — updated on re-forward.
    """
    if not django_req:
        return ""

    # Ensure foreign key dependencies exist
    save_request(django_req)
    if admin_user:
        sync_user(admin_user)
    else:
        dummy_adm = _uid("user", 0)
        _ensure_dummy_user(dummy_adm, "System Admin", "Admin")

    if tsp_user:
        sync_user(tsp_user)

    afr_uid  = _uid("afr", f"{django_req.id}:{admin_user.id if admin_user else 0}")
    req_uid  = _uid("request", django_req.id)
    adm_uid  = _uid("user", admin_user.id if admin_user else 0)

    # TSP side: prefer a real TSP user, else use a synthetic UUID
    if tsp_user:
        tsp_uid = _uid("user", tsp_user.id)
    else:
        tsp_uid = _uid("tsp_provider", django_req.tsp.id if django_req.tsp else 0)

    fwd_msg = (
        message
        or f"Request forwarded to {django_req.tsp.name if django_req.tsp else 'TSP'}"
    )

    # Make sure the synthetic TSP user exists so the FK is satisfied
    if not tsp_user:
        _ensure_tsp_provider_user(django_req, tsp_uid)

    sql = """
        INSERT INTO public.admin_forward_requests
            (id, request_id, admin_id, tsp_id, forwarded_message, forwarded_at, status)
        VALUES (%s, %s, %s, %s, %s, NOW(), 'Forwarded')
        ON CONFLICT (id) DO UPDATE SET
            forwarded_message = EXCLUDED.forwarded_message,
            forwarded_at      = NOW(),
            status            = 'Forwarded'
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (afr_uid, req_uid, adm_uid, tsp_uid, fwd_msg))
    finally:
        c.close()
    return afr_uid


def _ensure_tsp_provider_user(django_req, tsp_uid: str):
    """
    If no real TSP user account exists, insert a placeholder row so the FK works.
    """
    tsp = django_req.tsp
    if not tsp:
        return
    sql = """
        INSERT INTO public.users
            (id, full_name, email, mobile_number, role, is_active, created_at, updated_at)
        VALUES (%s, %s, %s, %s, 'TSP', TRUE, NOW(), NOW())
        ON CONFLICT (id) DO NOTHING
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (
                    tsp_uid,
                    tsp.name,
                    tsp.contact_email or f"{tsp.code.lower()}@tsp.local",
                    tsp.mobile_number or "",
                ))
    finally:
        c.close()


# ============================================================
# 4. TSP RESPONSE
# ============================================================
def save_tsp_response(django_req, django_resp, tsp_user) -> str:
    """Upsert a row in tsp_responses. Handles both matched (with request) and
    unmatched (request=None) TSP responses so nothing is silently dropped."""
    if not django_resp:
        return ""

    # ── Ensure dummy TSP user exists for FK ──────────────────────────────────
    if tsp_user:
        sync_user(tsp_user)
    else:
        dummy_tsp = _uid("user", 0)
        _ensure_dummy_user(dummy_tsp, "System TSP", "TSP")
    tsp_uid = _uid("user", tsp_user.id) if tsp_user else _uid("user", 0)

    tr_uid = _uid("tsp_response", django_resp.id)

    resp_data = json.dumps({
        "subscriber_status": django_resp.subscriber_status,
        "circle":            django_resp.circle,
        "activation_date":   str(django_resp.activation_date) if django_resp.activation_date else None,
        "tsp_provider":      django_resp.tsp_provider,
        "mobile_number":     django_resp.mobile_number,
        "additional_notes":  django_resp.additional_notes,
        "status":            django_resp.status,
    })

    # ── CASE 1: Unmatched response (no linked request) ───────────────────────
    if not django_req:
        # Save as an orphan / unmatched response so admins can review it
        # Try inserting into tsp_responses with NULL request_id
        sql_orphan = """
            INSERT INTO public.tsp_responses
                (id, request_id, tsp_id, response_message, response_data, response_date, created_at)
            VALUES (%s, NULL, %s, %s, %s::jsonb, CURRENT_DATE, NOW())
            ON CONFLICT (id) DO UPDATE SET
                response_message = EXCLUDED.response_message,
                response_data    = EXCLUDED.response_data,
                response_date    = CURRENT_DATE
        """
        c = _conn()
        try:
            with c:
                with c.cursor() as cur:
                    cur.execute(sql_orphan, (tr_uid, tsp_uid, django_resp.details, resp_data))
            print(f"[Supabase] Saved unmatched TSP response id={django_resp.id} (no linked request).")
        except Exception as exc:
            # If NULL request_id violates FK, store metadata in response_data only
            print(f"[Supabase] Could not save unmatched TSP response (FK constraint): {exc}")
        finally:
            c.close()
        return tr_uid

    # ── CASE 2: Matched response (has a linked request) ──────────────────────
    save_request(django_req)
    req_uid = _uid("request", django_req.id)

    sql = """
        INSERT INTO public.tsp_responses
            (id, request_id, tsp_id, response_message, response_data, response_date, created_at)
        VALUES (%s, %s, %s, %s, %s::jsonb, CURRENT_DATE, NOW())
        ON CONFLICT (id) DO UPDATE SET
            response_message = EXCLUDED.response_message,
            response_data    = EXCLUDED.response_data,
            response_date    = CURRENT_DATE
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (tr_uid, req_uid, tsp_uid, django_resp.details, resp_data))
    finally:
        c.close()
    return tr_uid


# ============================================================
# 5. ADMIN → OFFICER RESPONSE FORWARD
# ============================================================
def save_admin_forward_response(django_req, django_resp, admin_user) -> str:
    """Upsert admin_forward_responses + officer_received_responses."""
    if not django_req:
        return ""

    # Ensure foreign key dependencies exist
    save_request(django_req)
    if admin_user:
        sync_user(admin_user)
    else:
        dummy_adm = _uid("user", 0)
        _ensure_dummy_user(dummy_adm, "System Admin", "Admin")

    if django_req.officer:
        sync_user(django_req.officer)
    else:
        dummy_off = _uid("user", 0)
        _ensure_dummy_user(dummy_off, "System Officer", "Officer")

    if django_resp:
        tsp_user = getattr(django_resp, 'submitted_by', None) or getattr(django_resp, 'created_by', None)
        save_tsp_response(django_req, django_resp, tsp_user)
    else:
        resp_uid = _uid("tsp_response", 0)
        _ensure_dummy_tsp_response(django_req, resp_uid)

    afr_resp_uid = _uid("afr_resp", django_req.id)
    req_uid      = _uid("request", django_req.id)
    adm_uid      = _uid("user", admin_user.id if admin_user else 0)
    off_uid      = _uid("user", django_req.officer_id if django_req.officer_id else 0)
    resp_uid     = _uid("tsp_response", django_resp.id) if django_resp else _uid("tsp_response", 0)

    sql_afr = """
        INSERT INTO public.admin_forward_responses
            (id, request_id, response_id, admin_id, officer_id,
             forwarded_response, forwarded_at, status)
        VALUES (%s, %s, %s, %s, %s, %s, NOW(), 'Forwarded')
        ON CONFLICT (id) DO UPDATE SET
            forwarded_response = EXCLUDED.forwarded_response,
            forwarded_at       = NOW(),
            status             = 'Forwarded'
    """
    sql_orr = """
        INSERT INTO public.officer_received_responses
            (id, request_id, officer_id, response_id, received_response, received_at, is_read)
        VALUES (%s, %s, %s, %s, %s, NOW(), FALSE)
        ON CONFLICT (id) DO UPDATE SET
            received_response = EXCLUDED.received_response,
            received_at       = NOW()
    """
    orr_uid  = _uid("orr", django_req.id)
    response_text = django_req.response or ""

    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql_afr, (
                    afr_resp_uid, req_uid, resp_uid, adm_uid, off_uid, response_text
                ))
                cur.execute(sql_orr, (
                    orr_uid, req_uid, off_uid, resp_uid, response_text
                ))
    finally:
        c.close()
    return afr_resp_uid


# ============================================================
# 6. STATUS LOG (audit trail)
# ============================================================
def log_status(django_req, action_by_user, action_type: str,
               action_details: str = "", old_status: str = "", new_status: str = ""):
    """Append one audit row to request_status_logs."""
    if not django_req:
        return

    # Ensure foreign key dependencies exist
    save_request(django_req)
    if action_by_user:
        sync_user(action_by_user)
    else:
        dummy_user = _uid("user", 0)
        _ensure_dummy_user(dummy_user, "System User", "Officer")

    log_uid  = str(_uuid_mod.uuid4())           # always a fresh UUID
    req_uid  = _uid("request", django_req.id)
    user_uid = _uid("user", action_by_user.id) if action_by_user else _uid("user", 0)

    sql = """
        INSERT INTO public.request_status_logs
            (id, request_id, action_by, action_type,
             action_details, old_status, new_status, created_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, NOW())
    """
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (
                    log_uid, req_uid, user_uid,
                    action_type, action_details, old_status, new_status,
                ))
    finally:
        c.close()


# ============================================================
# Async wrappers — fire-and-forget background threads
# ============================================================
def _async(fn, *args, **kwargs):
    import sys
    if 'test' in sys.argv:
        return
    def _run():
        try:
            fn(*args, **kwargs)
        except Exception as exc:
            print(f"[Supabase] {fn.__name__} failed: {exc}")
    threading.Thread(target=_run, daemon=True).start()


def async_sync_user(user):
    _async(sync_user, user)


def async_save_request(req):
    _async(save_request, req)


def async_save_admin_forward_request(req, admin, tsp_user=None, message=""):
    _async(save_admin_forward_request, req, admin, tsp_user, message)


def async_save_tsp_response(req, resp, tsp_user):
    _async(save_tsp_response, req, resp, tsp_user)


def async_save_admin_forward_response(req, resp, admin):
    _async(save_admin_forward_response, req, resp, admin)


def async_log_status(req, user, action_type, details="", old_status="", new_status=""):
    _async(log_status, req, user, action_type, details, old_status, new_status)


def save_login_detail(django_login_detail) -> str:
    """Upsert/Insert a LoginDetail record into Supabase."""
    if not django_login_detail:
        return ""
    
    ld_uid = _uid("login_detail", django_login_detail.id)
    user_uid = _uid("user", django_login_detail.user_id) if django_login_detail.user_id else None
    role = _ROLE.get(str(django_login_detail.role), "Officer")
    
    sql = """
        INSERT INTO public.login_details
            (id, user_id, username, role, ip_address, user_agent, login_time)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (id) DO NOTHING
    """
    
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (
                    ld_uid,
                    user_uid,
                    django_login_detail.username,
                    role,
                    django_login_detail.ip_address,
                    django_login_detail.user_agent,
                    django_login_detail.login_time
                ))
    finally:
        c.close()
    return ld_uid


def async_save_login_detail(login_detail):
    _async(save_login_detail, login_detail)


def sync_tsp_setting(django_tsp_setting) -> str:
    """Upsert a TspSetting record into Supabase."""
    if not django_tsp_setting:
        return ""
    
    uid = _uid("tsp_setting_name", django_tsp_setting.tsp_name)
    
    sql = """
        INSERT INTO public.tsp_settings
            (id, tsp_name, forward_number, sms_template, is_active, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, NOW())
        ON CONFLICT (tsp_name) DO UPDATE SET
            forward_number = EXCLUDED.forward_number,
            sms_template   = EXCLUDED.sms_template,
            is_active      = EXCLUDED.is_active,
            updated_at     = NOW()
    """
    
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (
                    uid,
                    django_tsp_setting.tsp_name,
                    django_tsp_setting.forward_number,
                    django_tsp_setting.sms_template,
                    django_tsp_setting.is_active,
                    django_tsp_setting.created_at or django_tsp_setting.updated_at,
                ))
    finally:
        c.close()
    return uid


def delete_tsp_setting(django_setting_id_or_name) -> None:
    """Delete a TspSetting record from Supabase."""
    if isinstance(django_setting_id_or_name, str) and not str(django_setting_id_or_name).isdigit():
        uid = _uid("tsp_setting_name", django_setting_id_or_name)
    else:
        uid = _uid("tsp_setting", django_setting_id_or_name)
        
    sql = "DELETE FROM public.tsp_settings WHERE id = %s"
    
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (uid,))
    finally:
        c.close()


def async_sync_tsp_setting(setting):
    _async(sync_tsp_setting, setting)


def async_delete_tsp_setting(setting_id):
    _async(delete_tsp_setting, setting_id)


def sync_tsp_provider_as_setting(django_provider) -> str:
    """Upsert a TSPProvider record's forwarding template into Supabase tsp_settings table."""
    if not django_provider:
        return ""
    
    # Map name to canonical name e.g. Airtel, Jio, Vi, BSNL
    name = django_provider.name.lower()
    code = django_provider.code.upper()
    target_name = django_provider.name
    if 'jio' in name or code == 'JIO':
        target_name = 'Jio'
    elif 'airtel' in name or code == 'AIRTEL':
        target_name = 'Airtel'
    elif 'vi' in name or code == 'VI':
        target_name = 'Vi'
    elif 'bsnl' in name or code == 'BSNL':
        target_name = 'BSNL'

    uid = _uid("tsp_setting_name", target_name)

    sql = """
        INSERT INTO public.tsp_settings
            (id, tsp_name, forward_number, sms_template, is_active, created_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, NOW())
        ON CONFLICT (tsp_name) DO UPDATE SET
            forward_number = EXCLUDED.forward_number,
            sms_template   = EXCLUDED.sms_template,
            is_active      = EXCLUDED.is_active,
            updated_at     = NOW()
    """
    
    c = _conn()
    try:
        with c:
            with c.cursor() as cur:
                cur.execute(sql, (
                    uid,
                    target_name,
                    django_provider.mobile_number,
                    django_provider.sms_template or f"Loc <Number>",
                    django_provider.is_active,
                    django_provider.created_at,
                ))
    finally:
        c.close()
    return uid


def async_sync_tsp_provider_as_setting(provider):
    _async(sync_tsp_provider_as_setting, provider)


