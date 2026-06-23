import os
import django
import urllib.request
import json

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from django.conf import settings

api_key = getattr(settings, 'TEXTBEE_API_KEY', '')
device_id = getattr(settings, 'TEXTBEE_DEVICE_ID', '')
url = f'https://api.textbee.dev/api/v1/gateway/devices/{device_id}/get-received-sms'

req = urllib.request.Request(url, headers={'x-api-key': api_key, 'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req) as res:
        data = json.loads(res.read().decode('utf-8'))
        msgs = data.get('data', [])
        with open('sms_list.txt', 'w', encoding='utf-8') as f:
            f.write(f"Total messages: {len(msgs)}\n")
            for i, m in enumerate(msgs):
                f.write(f"{i}: Sender: {m.get('sender')} | Msg: {repr(m.get('message'))} | Date: {m.get('receivedAt')}\n")
        print("Successfully wrote to sms_list.txt")
except Exception as e:
    print(f"Error: {e}")
