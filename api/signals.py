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


# --- Dashboard Cache Invalidation Signals ---
from django.core.cache import cache
from django.db.models.signals import post_save, post_delete
from django.dispatch import receiver
from api.models import Request, TSPProvider, TspSetting, SystemNotification, ActivityLog, SMSLog, SystemSetting, UserRole

def invalidate_dashboard_cache(user_id=None, role=None, tsp_id=None, clear_all=False, clear_admins=False):
    """Target-specific dashboard cache invalidation."""
    try:
        if clear_all:
            cache.clear()
            print("[SIGNALS] Dashboard Cache: Cleared entire cache.")
            return

        if user_id:
            cache.delete(f"dashboard_data_u{user_id}_role{role}_login0")
            cache.delete(f"dashboard_data_u{user_id}_role{role}_login1")
            print(f"[SIGNALS] Dashboard Cache: Invalidated user {user_id} ({role}).")

        if clear_admins:
            admin_ids = User.objects.filter(role=UserRole.ADMIN).values_list('id', flat=True)
            for admin_id in admin_ids:
                cache.delete(f"dashboard_data_u{admin_id}_role{UserRole.ADMIN}_login0")
                cache.delete(f"dashboard_data_u{admin_id}_role{UserRole.ADMIN}_login1")
            print("[SIGNALS] Dashboard Cache: Invalidated all admins.")

        if tsp_id:
            tsp_user_ids = User.objects.filter(role=UserRole.TSP, tsp_provider_id=tsp_id).values_list('id', flat=True)
            for u_id in tsp_user_ids:
                cache.delete(f"dashboard_data_u{u_id}_role{UserRole.TSP}_login0")
                cache.delete(f"dashboard_data_u{u_id}_role{UserRole.TSP}_login1")
            print(f"[SIGNALS] Dashboard Cache: Invalidated TSP provider {tsp_id} reps.")
    except Exception as e:
        print(f"[SIGNALS] Dashboard Cache Invalidation Error: {e}")


@receiver([post_save, post_delete], sender=Request)
def on_request_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    # Invalidate the creating officer
    if instance.officer_id:
        invalidate_dashboard_cache(user_id=instance.officer_id, role=UserRole.OFFICER)
    # Invalidate the assigned TSP reps
    if instance.tsp_id:
        invalidate_dashboard_cache(tsp_id=instance.tsp_id)
    # Invalidate admins (they see all requests and stats)
    invalidate_dashboard_cache(clear_admins=True)


@receiver([post_save, post_delete], sender=TSPProvider)
def on_tsp_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    # Changes to providers affect general options, clear all to be safe
    invalidate_dashboard_cache(clear_all=True)


@receiver([post_save, post_delete], sender=TspSetting)
def on_tsp_setting_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    invalidate_dashboard_cache(clear_admins=True)


@receiver([post_save, post_delete], sender=SystemNotification)
def on_notification_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    if instance.user_id:
        invalidate_dashboard_cache(user_id=instance.user_id, role=instance.user.role)


@receiver(post_save, sender=ActivityLog)
def on_activity_log_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    invalidate_dashboard_cache(clear_admins=True)


@receiver(post_save, sender=SMSLog)
def on_sms_log_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    invalidate_dashboard_cache(clear_admins=True)


@receiver([post_save, post_delete], sender=SystemSetting)
def on_system_setting_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    # Changes to key system settings require fresh loads for all users
    invalidate_dashboard_cache(clear_all=True)


@receiver([post_save, post_delete], sender=User)
def on_user_change(sender, instance, **kwargs):
    if kwargs.get('raw', False):
        return
    invalidate_dashboard_cache(user_id=instance.id, role=instance.role)
    if instance.role == UserRole.OFFICER:
        invalidate_dashboard_cache(clear_admins=True)
    # Also invalidate auth cache for this user
    cache.delete(f"auth_user_{instance.id}")
    try:
        if hasattr(instance, 'auth_token') and instance.auth_token:
            cache.delete(f"auth_token_credentials_{instance.auth_token.key}")
            cache.delete(f"auth_token_obj_{instance.auth_token.pk}")
    except Exception:
        pass
