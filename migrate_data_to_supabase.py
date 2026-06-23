import os
import sys
import django

# Setup Django environment
sys.path.insert(0, os.path.dirname(__file__))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from api.models import (
    TSPProvider, User, Request, SMSLog, ChatMessage,
    RequestStatusLog, TSPResponse, PermissionSetting,
    SystemNotification, ActivityLog, SystemSetting
)
from rest_framework.authtoken.models import Token

def migrate_model(model_class):
    name = model_class.__name__
    print(f"Migrating {name}...")
    
    # Fetch from SQLite database
    sqlite_items = model_class.objects.using('sqlite').all()
    count = sqlite_items.count()
    print(f"  Found {count} items in SQLite")
    
    success = 0
    errors = 0
    for item in sqlite_items:
        try:
            # We explicitly check if it exists in PostgreSQL, and insert/update accordingly
            if model_class.objects.using('default').filter(pk=item.pk).exists():
                item.save(using='default')
            else:
                item.save(using='default', force_insert=True)
            success += 1
        except Exception as e:
            errors += 1
            print(f"  [ERR] Failed to migrate {name} with pk={item.pk}: {e}")
            
    print(f"  Done: {success} succeeded, {errors} failed\n")

if __name__ == '__main__':
    # Order is extremely important due to ForeignKey dependencies!
    models_to_migrate = [
        TSPProvider,
        User,
        Request,
        SMSLog,
        ChatMessage,
        RequestStatusLog,
        TSPResponse,
        PermissionSetting,
        SystemNotification,
        ActivityLog,
        SystemSetting,
        Token
    ]
    
    print("=" * 60)
    print("  Migrating Django Data SQLite -> Supabase PostgreSQL")
    print("=" * 60 + "\n")
    
    for model in models_to_migrate:
        migrate_model(model)
        
    print("=" * 60)
    print("  Data Migration Completed!")
    print("=" * 60)
