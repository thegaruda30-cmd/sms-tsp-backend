import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from rest_framework.authtoken.models import Token

print("Active REST Framework Auth Tokens:")
for t in Token.objects.all():
    print(f"User: {t.user.username:<20} | Token: {t.key}")
