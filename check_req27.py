import os
import django
import json
import urllib.request
from django.conf import settings

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from api.models import Request, SMSLog, RequestStatusLog, TSPResponse
from api.file_db import load_processed_sms_ids

# Check Request 27
try:
    req = Request.objects.get(ticket_id="TSPTKT-000027")
    print(f"Request 27: ID={req.id} | Mobile={req.mobile_number} | TSP={req.tsp.name} | Status={req.status} | Admin Status={req.admin_status} | Response={repr(req.response)}")
except Request.DoesNotExist:
    print("Request 27 not found in DB!")

print("\n--- RECENT CHAT MESSAGES/STATUS LOGS FOR TSPTKT-000027 ---")
for r in Request.objects.filter(ticket_id="TSPTKT-000027"):
    for log in RequestStatusLog.objects.filter(request=r).order_by('id'):
         print(f"Log: Status={log.status} | Remarks={repr(log.remarks)}")

# Check TextBee received SMS with a 30s timeout
api_key = getattr(settings, 'TEXTBEE_API_KEY', '')
device_id = getattr(settings, 'TEXTBEE_DEVICE_ID', '')
url = f"https://api.textbee.dev/api/v1/gateway/devices/{device_id}/get-received-sms"

processed_ids = load_processed_sms_ids()
req_obj = urllib.request.Request(url, headers={"x-api-key": api_key, "User-Agent": "Mozilla/5.0"}, method='GET')
try:
    with urllib.request.urlopen(req_obj, timeout=30) as response:
        res_data = json.loads(response.read().decode('utf-8'))
        messages = res_data.get('data', [])
        print("\n--- TEXTBEE RECEIVED SMS ---")
        for m in messages[:10]:
            msg_id = m.get('_id')
            sender = m.get('sender')
            msg = m.get('message', '')
            received_at = m.get('receivedAt')
            is_processed = msg_id in processed_ids
            safe_msg = msg.encode('ascii', errors='replace').decode('ascii')
            print(f"ID: {msg_id} | Sender: {sender} | Processed: {is_processed} | Msg: {repr(safe_msg)} | Date: {received_at}")
except Exception as e:
    print(f"Error fetching TextBee SMS: {e}")
