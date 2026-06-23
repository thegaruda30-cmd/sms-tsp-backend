# type: ignore
# mypy: ignore-errors
from django.contrib import admin
from django.contrib.auth.admin import UserAdmin
from .models import User, TSPProvider, Request, RequestStatusLog, TSPResponse, PermissionSetting, SystemNotification, ActivityLog, SystemSetting, AdminForwardRequest, LoginDetail


# Custom User Admin
class CustomUserAdmin(UserAdmin):
    fieldsets = tuple(UserAdmin.fieldsets or ()) + (
        ('Role & TSP Info', {'fields': ('role', 'tsp_provider')}),
    )
    add_fieldsets = tuple(UserAdmin.add_fieldsets or ()) + (
        ('Role & TSP Info', {'fields': ('role', 'tsp_provider')}),
    )
    list_display = ['username', 'email', 'role', 'tsp_provider', 'is_staff']
    list_filter = ['role', 'is_staff', 'is_superuser']

admin.site.register(User, CustomUserAdmin)
admin.site.register(TSPProvider)
admin.site.register(Request)
admin.site.register(RequestStatusLog)
admin.site.register(TSPResponse)
admin.site.register(PermissionSetting)
admin.site.register(SystemNotification)
admin.site.register(ActivityLog)
admin.site.register(SystemSetting)
admin.site.register(AdminForwardRequest)
admin.site.register(LoginDetail)
