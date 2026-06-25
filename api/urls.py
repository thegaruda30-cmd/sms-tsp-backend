from django.urls import path, include
from rest_framework.routers import DefaultRouter
from api.views import (
    CustomAuthToken, TSPProviderViewSet, RequestViewSet,
    AdminDashboardStatsView, OfficerDashboardStatsView, TSPDashboardStatsView,
    SystemSettingView, PermissionViewSet, NotificationViewSet,
    ActivityLogViewSet, ExportReportView, FieldOfficerListView,
    ChatMessageViewSet, DatabaseBrowserView, TSPResponseViewSet, SMSLogViewSet,
    PollSMSView, TextBeeWebhookView, UserProfileView, TspSettingViewSet,
    HealthCheckView, DashboardView
)

router = DefaultRouter()
router.register('requests', RequestViewSet, basename='request')
router.register('tsps', TSPProviderViewSet, basename='tsp')
router.register('tsp-settings', TspSettingViewSet, basename='tsp-setting')
router.register('permissions', PermissionViewSet, basename='permission')
router.register('notifications', NotificationViewSet, basename='notification')
router.register('logs', ActivityLogViewSet, basename='activity-log')
router.register('chats', ChatMessageViewSet, basename='chat')
router.register('tsp-responses', TSPResponseViewSet, basename='tsp-response')
router.register('sms-logs', SMSLogViewSet, basename='sms-log')


urlpatterns = [
    path('', include(router.urls)),
    path('health/', HealthCheckView.as_view(), name='health'),
    path('login/', CustomAuthToken.as_view(), name='login'),
    path('profile/', UserProfileView.as_view(), name='profile'),
    path('settings/', SystemSettingView.as_view(), name='settings'),
    path('stats/admin/', AdminDashboardStatsView.as_view(), name='stats-admin'),
    path('stats/officer/', OfficerDashboardStatsView.as_view(), name='stats-officer'),
    path('stats/tsp/', TSPDashboardStatsView.as_view(), name='stats-tsp'),
    path('officers/', FieldOfficerListView.as_view(), name='officers-list'),
    path('reports/', ExportReportView.as_view(), name='export-reports'),
    path('database-browser/', DatabaseBrowserView.as_view(), name='database-browser'),
    path('poll-sms/', PollSMSView.as_view(), name='poll-sms'),
    # Combined dashboard endpoint — returns all initial data in one request
    path('dashboard/', DashboardView.as_view(), name='dashboard'),
    # TextBee webhook — called automatically by TextBee when an SMS arrives (no auth needed)
    path('textbee-webhook/', TextBeeWebhookView.as_view(), name='textbee-webhook'),
]

