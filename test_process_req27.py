import os
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from api.views import process_single_received_sms, normalize_phone
from api.models import Request, TSPProvider, RequestStatus

if __name__ == '__main__':
    # 1. Inspect providers
    for t in TSPProvider.objects.all():
        print(f"TSP: {t.name} (Code: {t.code}) | Mobile: {t.mobile_number} | Normalized: {normalize_phone(t.mobile_number)}")

    # 2. Inspect active requests
    active = Request.objects.filter(status__in=[RequestStatus.FORWARDED, RequestStatus.PROCESSING]).order_by('-forwarded_at')
    print(f"\n--- ACTIVE REQUESTS ({len(active)}) ---")
    for r in active:
        print(f"Req ID: {r.id} | Mobile: {r.mobile_number} | TSP: {r.tsp.name} | Status: {r.status} | Forwarded At: {r.forwarded_at}")

    # 3. Simulate process_single_received_sms
    print("\n--- SIMULATING process_single_received_sms ---")
    success = process_single_received_sms(
        sms_id="6a30e5d4d2404ce6432e65b9",
        sender="+917353224350",
        message="Okay",
        received_at_str="2026-06-16T05:57:36.000Z"
    )
    print(f"Result: {success}")
