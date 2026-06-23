import os
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from api.models import ActivityLog

def safe_str(s):
    if s is None:
        return ""
    return str(s).encode('ascii', errors='replace').decode('ascii')

for log in ActivityLog.objects.all().order_by('-id')[:50]:
    print(f"ID: {log.id} | Action: {safe_str(log.action)} | User: {safe_str(log.user)} | Details: {safe_str(log.details)}")
