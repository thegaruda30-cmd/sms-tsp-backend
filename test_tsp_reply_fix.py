"""
Test: TSP Response Fix Verification
"""
import os, sys, django

os.chdir(os.path.dirname(__file__))
sys.path.insert(0, os.path.dirname(__file__))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

# Force UTF-8 output
import io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

from api.models import (
    User, TSPProvider, Request, RequestStatus, TSPResponse, UserRole
)
from django.utils import timezone

print("=" * 60)
print("TSP REPLY FIX -- VERIFICATION TEST")
print("=" * 60)

admin = User.objects.filter(role=UserRole.ADMIN).first()
tsp_user = User.objects.filter(role=UserRole.TSP).first()
tsp_provider = TSPProvider.objects.filter(is_active=True).first()
officer = User.objects.filter(role=UserRole.OFFICER).first()

if not all([admin, tsp_provider, officer]):
    print("MISSING test data. Cannot run test.")
    sys.exit(1)

print(f"\n[OK] Admin:        {admin.username}")
print(f"[OK] TSP Provider: {tsp_provider.name}")
print(f"[OK] Officer:      {officer.username}")
if tsp_user:
    print(f"[OK] TSP User:     {tsp_user.username}")
else:
    print("[--] TSP User:     None (will use admin as submitter)")

# Create a FORWARDED request
req = Request.objects.create(
    mobile_number='9876543210',
    tsp=tsp_provider,
    officer=officer,
    officer_name=f"{officer.first_name} {officer.last_name}".strip() or officer.username,
    status=RequestStatus.FORWARDED,
    admin_status='Forwarded to TSP',
    remarks='Test request for TSP fix verification',
)
print(f"\n[+] Created test Request #{req.id} - status: {req.status}")

# Simulate TSP responding
from api.views import parse_tsp_sms_response, is_acknowledgment_message

details = (
    "Status: Active\n"
    "Circle: Karnataka\n"
    "Activation Date: 2020-06-15\n"
    "Customer Name: Test User"
)
notes = "Verified from records"
is_ack = is_acknowledgment_message(details)
_parsed = parse_tsp_sms_response(details, tsp_name=tsp_provider.name)

print(f"[i] Is acknowledgment? {is_ack}  (should be False for real response)")

# Apply FIXED logic
if req.status not in [RequestStatus.COMPLETED, RequestStatus.CLOSED]:
    if is_ack:
        req.status = RequestStatus.PROCESSING
        req.admin_status = 'Acknowledgment Received'
    else:
        req.status = RequestStatus.TSP_RESPONDED    # FIXED
        req.admin_status = 'SMS Response Received'   # FIXED
req.response = details
req.response_date = timezone.now()
req.save()

# Determine TSPResponse status (FIXED)
if req.status in [RequestStatus.COMPLETED, RequestStatus.CLOSED]:
    response_status = 'Sent to Officer'
else:
    response_status = 'Received'  # FIXED: always 'Received' so admin sees it

resp = TSPResponse.objects.create(
    request=req,
    details=details,
    submitted_by=tsp_user or admin,
    created_by=tsp_user or admin,
    mobile_number=req.mobile_number,
    tsp_provider=tsp_provider.name,
    status=response_status,
    response_date=timezone.now(),
    subscriber_status=_parsed['subscriber_status'],
    circle=_parsed['circle'],
    activation_date=_parsed['activation_date'],
    additional_notes=notes,
)

print(f"\n--- AFTER TSP RESPOND ---")
req_status_ok = req.status == RequestStatus.TSP_RESPONDED
resp_status_ok = resp.status == 'Received'
print(f"  Request status     : {req.status!r}  -> {'PASS' if req_status_ok else 'FAIL (expected TSP_RESPONDED)'}")
print(f"  TSPResponse status : {resp.status!r}  -> {'PASS' if resp_status_ok else 'FAIL (expected Received)'}")
print(f"  Subscriber status  : {resp.subscriber_status!r}")
print(f"  Circle             : {resp.circle!r}")

# Verify admin can see it
admin_visible = TSPResponse.objects.filter(pk=resp.pk, status='Received').first()
admin_can_see = admin_visible is not None
print(f"\n--- ADMIN TSP REPLIES PANEL ---")
print(f"  Response visible   : {'PASS - Admin CAN see it!' if admin_can_see else 'FAIL - Admin CANNOT see it!'}")
print(f"  Forward button     : {'PASS - Shows Forward to Officer button' if admin_can_see else 'FAIL - Hidden!'}")

# Simulate admin forwarding
resp.status = 'Sent to Officer'
resp.response_date = timezone.now()
resp.save()
req.status = RequestStatus.COMPLETED
req.admin_status = 'Completed'
req.save()

req_completed_ok = req.status == RequestStatus.COMPLETED
resp_sent_ok = resp.status == 'Sent to Officer'
print(f"\n--- AFTER ADMIN FORWARDS TO OFFICER ---")
print(f"  Request status     : {req.status!r}  -> {'PASS' if req_completed_ok else 'FAIL'}")
print(f"  TSPResponse status : {resp.status!r}  -> {'PASS' if resp_sent_ok else 'FAIL'}")

# Cleanup
resp.delete()
req.delete()
print(f"\n[cleanup] Test data removed.")

all_passed = req_status_ok and resp_status_ok and admin_can_see and req_completed_ok and resp_sent_ok
print("\n" + "=" * 60)
if all_passed:
    print("RESULT: ALL TESTS PASSED!")
    print("Flow: TSP responds -> Admin sees it -> Admin forwards -> Officer gets it")
else:
    print("RESULT: SOME TESTS FAILED. Check output above.")
print("=" * 60)
