"""
URL configuration for backend project.
"""
from django.contrib import admin
from django.urls import path, include
from django.http import JsonResponse
from django.utils import timezone

def api_root(request):
    return JsonResponse({
        "system": "SMS TSP Information Management System",
        "version": "1.0.0",
        "status": "running",
        "time": timezone.now().isoformat(),
        "endpoints": {
            "api": "/api/",
            "admin_panel": "/admin/",
            "login": "/api/login/",
            "requests": "/api/requests/",
            "tsps": "/api/tsps/",
        }
    })

urlpatterns = [
    path('', api_root, name='api-root'),
    path('admin/', admin.site.urls),
    path('api/', include('api.urls')),
]
