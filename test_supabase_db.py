"""
Quick smoke-test for supabase_db.py
Run: venv\Scripts\python test_supabase_db.py
"""
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
sys.path.insert(0, os.path.dirname(__file__))
django.setup()

import psycopg2
from api.supabase_db import _conn, _uid, sync_user, save_request, log_status
from api.models import User, Request

if __name__ == '__main__':
    print("\n" + "="*60)
    print("  Supabase Integration Smoke Test")
    print("="*60)

    # 1. Connection
    try:
        c = _conn()
        c.close()
        print("\n  [OK] Connected to Supabase")
    except Exception as e:
        print(f"\n  [ERR] Connection failed: {e}")
        sys.exit(1)

    # 2. Sync all existing Django users
    users = User.objects.all()
    print(f"\n  Syncing {users.count()} users...")
    for u in users:
        try:
            uid = sync_user(u)
            print(f"  [OK] User '{u.username}' ({u.role}) -> {uid[:18]}...")
        except Exception as e:
            print(f"  [ERR] User '{u.username}': {e}")

    # 3. Mirror all existing requests
    requests = Request.objects.all().order_by('-id')[:10]
    print(f"\n  Mirroring {requests.count()} most recent requests...")
    from api.supabase_db import save_request, log_status
    for req in requests:
        try:
            uid = save_request(req)
            print(f"  [OK] Request #{req.id} ({req.status}) -> {uid[:18]}...")
        except Exception as e:
            print(f"  [ERR] Request #{req.id}: {e}")

    # 4. Verify counts in Supabase
    c = _conn()
    cur = c.cursor()
    tables = ['users', 'requests', 'admin_forward_requests',
              'tsp_responses', 'admin_forward_responses',
              'officer_received_responses', 'request_status_logs']
    print("\n  Row counts in Supabase tables:")
    for t in tables:
        cur.execute(f"SELECT COUNT(*) FROM public.{t}")
        cnt = cur.fetchone()[0]
        print(f"  [{cnt:>4}] {t}")
    cur.close()
    c.close()

    print("\n" + "="*60)
    print("  Smoke test complete!")
    print("="*60 + "\n")
