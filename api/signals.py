from django.db.models.signals import post_save
from django.dispatch import receiver
from django.contrib.auth import get_user_model
from api.supabase_db import async_sync_user

User = get_user_model()

@receiver(post_save, sender=User)
def sync_user_to_supabase(sender, instance, created, **kwargs):
    """Automatically sync any created or updated Django user to Supabase's public.users table."""
    if kwargs.get('raw', False):
        # Skip if loading data from raw sources/fixtures
        return
    try:
        async_sync_user(instance)
    except Exception as e:
        print(f"[SIGNALS] Failed to sync user {instance.username} to Supabase: {e}")


from django.contrib.auth.signals import user_logged_in
from django.contrib.auth.models import update_last_login

# Disconnect the default synchronous update_last_login handler so login responds instantly
user_logged_in.disconnect(update_last_login)

@receiver(user_logged_in)
def on_user_logged_in(sender, request, user, **kwargs):
    """Create a LoginDetail record on login and sync it to Supabase in the background."""
    import threading
    
    ip_address = ""
    user_agent = ""
    if request:
        try:
            ip_address = request.META.get('REMOTE_ADDR', '')
            x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
            if x_forwarded_for:
                ip_address = x_forwarded_for.split(',')[0].strip()
            user_agent = request.META.get('HTTP_USER_AGENT', '')
        except Exception:
            pass

    def _run_login_tasks():
        try:
            from django.utils import timezone
            from api.models import LoginDetail
            from api.supabase_db import async_save_login_detail
            
            # 1. Update last_login in the background
            user.last_login = timezone.now()
            user.save(update_fields=['last_login'])

            # 2. Create LoginDetail record in the database
            login_detail = LoginDetail.objects.create(
                user=user,
                username=user.username,
                role=user.role,
                ip_address=ip_address,
                user_agent=user_agent
            )
            
            # 3. Sync LoginDetail record to Supabase
            async_save_login_detail(login_detail)
            print(f"[SIGNALS] Logged login event and updated last_login in background for {user.username} ({user.role})")
        except Exception as e:
            print(f"[SIGNALS] Failed to process background login tasks: {e}")
        finally:
            try:
                from django.db import connections
                connections.close_all()
            except Exception:
                pass

    from django.db import transaction
    transaction.on_commit(lambda: threading.Thread(target=_run_login_tasks, daemon=True).start())
