"""
backfill_supabase.py
--------------------
One-time script to mirror ALL existing Django data into Supabase.

Run: venv\Scripts\python backfill_supabase.py
"""
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
sys.path.insert(0, os.path.dirname(__file__))
django.setup()

from api.models import User, Request, TSPResponse, RequestStatus, UserRole, TSPProvider
from api.supabase_db import (
    sync_user, save_request, save_admin_forward_request,
    save_tsp_response, save_admin_forward_response, log_status, _conn, _uid,
    sync_tsp_provider_as_setting
)

ok = 0
err = 0

def report(label, success, detail=""):
    global ok, err
    if success:
        ok += 1
        print(f"  [OK] {label}")
    else:
        err += 1
        print(f"  [ERR] {label}: {detail}")

print("\n" + "="*60)
print("  Supabase Full Backfill")
print("="*60)

# ── 1. Users ──────────────────────────────────────────────────
print(f"\n[1] Syncing all users...")
for u in User.objects.all():
    try:
        sync_user(u)
        report(f"User '{u.username}' ({u.role})", True)
    except Exception as e:
        report(f"User '{u.username}'", False, str(e))

# ── 2. All requests ───────────────────────────────────────────
print(f"\n[2] Mirroring all requests...")
for req in Request.objects.all().order_by('id'):
    try:
        save_request(req)
        report(f"Request #{req.id} ({req.status}) - {req.mobile_number}", True)
    except Exception as e:
        report(f"Request #{req.id}", False, str(e))

# ── 3. Admin-forward records for FORWARDED/PROCESSING/COMPLETED requests ──
print(f"\n[3] Backfilling admin_forward_requests...")
admin_user = User.objects.filter(role=UserRole.ADMIN).first()
forwarded_statuses = [
    RequestStatus.FORWARDED, RequestStatus.PROCESSING,
    RequestStatus.TSP_RESPONDED, RequestStatus.COMPLETED, RequestStatus.CLOSED
]
for req in Request.objects.filter(status__in=forwarded_statuses).order_by('id'):
    try:
        # Find which TSP user to link (prefer real user, else placeholder)
        tsp_user = User.objects.filter(
            role=UserRole.TSP, tsp_provider=req.tsp
        ).first()
        save_admin_forward_request(
            req, admin_user,
            tsp_user=tsp_user,
            message=f"Request forwarded to {req.tsp.name if req.tsp else 'TSP'}"
        )
        report(f"AdminForward -> Request #{req.id} to {req.tsp.name if req.tsp else 'N/A'}", True)
    except Exception as e:
        report(f"AdminForward -> Request #{req.id}", False, str(e))

# ── 4. TSP responses ──────────────────────────────────────────
print(f"\n[4] Backfilling tsp_responses...")
for resp in TSPResponse.objects.all().order_by('id'):
    if not resp.request:
        continue
    try:
        tsp_user = (resp.submitted_by
                    if resp.submitted_by and resp.submitted_by.role == UserRole.TSP
                    else User.objects.filter(
                            role=UserRole.TSP,
                            tsp_provider=resp.request.tsp
                        ).first())
        save_tsp_response(resp.request, resp, tsp_user)
        report(f"TSPResponse #{resp.id} for Request #{resp.request.id}", True)
    except Exception as e:
        report(f"TSPResponse #{resp.id}", False, str(e))

# ── 5. Admin-forward-response + officer-received for COMPLETED ────────────
print(f"\n[5] Backfilling admin_forward_responses + officer_received_responses...")
completed_reqs = Request.objects.filter(
    status__in=[RequestStatus.COMPLETED, RequestStatus.CLOSED]
).order_by('id')

for req in completed_reqs:
    tsp_resp = req.tsp_responses.first()
    if not tsp_resp:
        continue
    try:
        save_admin_forward_response(req, tsp_resp, admin_user)
        report(f"AdminForwardResp + OfficerReceived for Request #{req.id}", True)
    except Exception as e:
        report(f"AdminForwardResp for Request #{req.id}", False, str(e))

# ── 6. Status logs from RequestStatusLog ──────────────────────
print(f"\n[6] Backfilling request_status_logs...")
from api.models import RequestStatusLog
import uuid as _uuid_mod

_STATUS_MAP = {
    "PENDING":       "Submitted",
    "APPROVED":      "Sent_To_Admin",
    "REJECTED":      "Submitted",
    "FORWARDED":     "Forwarded_To_TSP",
    "PROCESSING":    "Forwarded_To_TSP",
    "TSP_RESPONDED": "Response_Received_From_TSP",
    "COMPLETED":     "Forwarded_To_Officer",
    "CLOSED":        "Completed",
}

for log in RequestStatusLog.objects.all().order_by('id'):
    try:
        req_uid  = _uid("request", log.request_id)
        user_uid = _uid("user", log.changed_by_id) if log.changed_by_id else _uid("user", 0)
        log_uid  = str(_uuid_mod.uuid5(
            _uuid_mod.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8"),
            f"statuslog:{log.id}"
        ))
        sql = """
            INSERT INTO public.request_status_logs
                (id, request_id, action_by, action_type,
                 action_details, old_status, new_status, created_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id) DO NOTHING
        """
        c = _conn()
        try:
            with c:
                with c.cursor() as cur:
                    cur.execute(sql, (
                        log_uid, req_uid, user_uid,
                        log.status,
                        log.remarks or "",
                        "",
                        _STATUS_MAP.get(str(log.status), str(log.status)),
                        log.timestamp,
                    ))
        finally:
            c.close()
        report(f"StatusLog #{log.id} -> {log.status}", True)
    except Exception as e:
        report(f"StatusLog #{log.id}", False, str(e))

# ── 7. TSP Settings ──────────────────────────────────────────
print(f"\n[7] Backfilling tsp_settings...")
for provider in TSPProvider.objects.all().order_by('id'):
    try:
        sync_tsp_provider_as_setting(provider)
        report(f"TSPProvider '{provider.name}' - template: {provider.sms_template}", True)
    except Exception as e:
        report(f"TSPProvider '{provider.name}'", False, str(e))

# ── Final counts ──────────────────────────────────────────────
c = _conn()
cur = c.cursor()
tables = [
    'users', 'requests', 'admin_forward_requests',
    'tsp_responses', 'admin_forward_responses',
    'officer_received_responses', 'request_status_logs',
    'tsp_settings'
]
print("\n" + "="*60)
print("  Final Supabase Table Counts")
print("="*60)
for t in tables:
    cur.execute(f"SELECT COUNT(*) FROM public.{t}")
    cnt = cur.fetchone()[0]
    print(f"  [{cnt:>4}] {t}")
cur.close()
c.close()

print(f"\n  Done: {ok} succeeded, {err} failed")
print("="*60 + "\n")
