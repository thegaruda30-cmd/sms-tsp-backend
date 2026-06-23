from django.apps import AppConfig


class ApiConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'api'

    def ready(self):
        """Start a background thread that polls TextBee for incoming SMS every 15 seconds."""
        import sys
        import os

        # Register signals
        import api.signals

        # Only run in the main process (not in migrations, tests, or reloader child)
        is_runserver = 'runserver' in sys.argv
        is_poll_cmd  = 'poll_sms' in sys.argv
        if not is_runserver and not is_poll_cmd:
            return

        # When Django's auto-reloader is active it spawns a child process with
        # RUN_MAIN='true'.  Only start the poller in that child so we don't
        # launch two poller threads.
        # If --noreload is used, RUN_MAIN is not set, so we also start then.
        run_main = os.environ.get('RUN_MAIN')
        if is_runserver and run_main != 'true':
            return

        import threading
        import time

        def _background_sms_poller():
            # Wait for the server to fully start before first poll
            time.sleep(3)
            print("[SMS Poller] Starting first poll...")
            poll_count = 0
            while True:
                try:
                    # Bypass the 10-sec cache by resetting it before each background poll
                    import api.views as _views
                    _views.LAST_POLL_TIME = 0
                    _views.poll_incoming_sms()
                    poll_count += 1
                    if poll_count % 4 == 0:  # Log every ~60 seconds
                        print(f"[SMS Poller] Background poll #{poll_count} complete.")
                except Exception as e:
                    print(f"[SMS Poller] Error during poll: {e}")
                finally:
                    # CRITICAL: Close Django DB connections after each poll.
                    # Background threads share no request context, so Django
                    # keeps connections open indefinitely — this causes
                    # 'database is locked' on SQLite and connection leaks.
                    try:
                        from django.db import connections
                        connections.close_all()
                    except Exception:
                        pass
                time.sleep(15)  # Poll every 15 seconds (was 30)

        poller_thread = threading.Thread(
            target=_background_sms_poller,
            daemon=True,
            name="sms-background-poller"
        )
        poller_thread.start()
        print("[SMS Poller] Background SMS polling started (every 15 seconds).")

