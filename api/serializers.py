# type: ignore
# mypy: ignore-errors
from rest_framework import serializers
from api.models import (
    User, TSPProvider, Request, RequestStatusLog, TSPResponse, PermissionSetting,
    SystemNotification, ActivityLog, SystemSetting, ChatMessage, SMSLog, TspSetting,
    UserRole, RequestStatus
)

class TSPProviderSerializer(serializers.ModelSerializer):
    class Meta:
        model = TSPProvider
        fields = ['id', 'name', 'code', 'contact_email', 'mobile_number', 'inbound_number', 'sms_template', 'is_default', 'is_active']

class SMSLogSerializer(serializers.ModelSerializer):
    class Meta:
        model = SMSLog
        fields = ['id', 'request', 'direction', 'operator', 'tsp_number', 'message', 'timestamp']

class UserSerializer(serializers.ModelSerializer):
    tsp_provider_details = TSPProviderSerializer(source='tsp_provider', read_only=True)
    direct_forward_allowed = serializers.SerializerMethodField()
    bypass_daily_limit = serializers.SerializerMethodField()
    bypass_requested = serializers.SerializerMethodField()
    extra_requests_limit = serializers.SerializerMethodField()
    bypass_expiry_date = serializers.SerializerMethodField()
    is_bypass_active = serializers.SerializerMethodField()
 
    class Meta:
        model = User
        fields = [
            'id', 'username', 'email', 'role', 'tsp_provider', 'tsp_provider_details',
            'direct_forward_allowed', 'bypass_daily_limit', 'bypass_requested',
            'extra_requests_limit', 'bypass_expiry_date', 'is_bypass_active',
            'first_name', 'last_name', 'mobile_number', 'station_name'
        ]
 
    def _get_perm(self, obj):
        try:
            return obj.permission
        except Exception:
            return None

    def get_direct_forward_allowed(self, obj):
        perm = self._get_perm(obj)
        return perm.direct_forward_allowed if perm else False
 
    def get_bypass_daily_limit(self, obj):
        perm = self._get_perm(obj)
        return perm.bypass_daily_limit if perm else False

    def get_bypass_requested(self, obj):
        perm = self._get_perm(obj)
        return perm.bypass_requested if perm else False

    def get_extra_requests_limit(self, obj):
        perm = self._get_perm(obj)
        return perm.extra_requests_limit if perm else 0

    def get_bypass_expiry_date(self, obj):
        perm = self._get_perm(obj)
        if perm:
            val = perm.bypass_expiry_date
            return val.isoformat() if val else None
        return None

    def get_is_bypass_active(self, obj):
        perm = self._get_perm(obj)
        if perm:
            if perm.bypass_daily_limit:
                if perm.bypass_expiry_date:
                    from django.utils import timezone
                    return perm.bypass_expiry_date >= timezone.now()
                return True
        return False

class RequestStatusLogSerializer(serializers.ModelSerializer):
    changed_by_name = serializers.CharField(source='changed_by.username', read_only=True)
    changed_by_role = serializers.CharField(source='changed_by.role', read_only=True)

    class Meta:
        model = RequestStatusLog
        fields = ['id', 'status', 'changed_by_name', 'changed_by_role', 'remarks', 'timestamp']

class TSPResponseSerializer(serializers.ModelSerializer):
    submitted_by_name = serializers.CharField(source='submitted_by.username', read_only=True)
    created_by_name = serializers.CharField(source='created_by.username', read_only=True)

    class Meta:
        model = TSPResponse
        fields = [
            'id', 'request', 'details', 'submitted_by', 'submitted_by_name', 'timestamp',
            'mobile_number', 'tsp_provider', 'subscriber_status', 'circle', 
            'activation_date', 'additional_notes', 'response_date', 'status',
            'created_by', 'created_by_name', 'created_at'
        ]

class RequestSerializer(serializers.ModelSerializer):
    tsp_details = TSPProviderSerializer(source='tsp', read_only=True)
    officer_details = UserSerializer(source='officer', read_only=True)
    status_logs = RequestStatusLogSerializer(many=True, read_only=True)
    tsp_response = TSPResponseSerializer(read_only=True)
    sms_logs = SMSLogSerializer(many=True, read_only=True)

    class Meta:
        model = Request
        fields = [
            'id', 
            'cr_no',
            'station_name',
            'location',
            'mobile_number', 
            'tsp', 
            'tsp_details', 
            'reason', 
            'status', 
            'officer', 
            'officer_details', 
            'officer_name',
            'remarks', 
            'admin_remarks',
            'is_auto_approved', 
            'created_at', 
            'updated_at', 
            'forwarded_at',
            'response',
            'response_date',
            'admin_status',
            'status_logs',
            'tsp_response',
            'subject',
            'message',
            'ticket_id',
            'sms_logs'
        ]
        read_only_fields = ['status', 'officer', 'officer_name', 'is_auto_approved', 'admin_remarks', 'forwarded_at', 'response', 'response_date', 'admin_status', 'ticket_id']

    def to_representation(self, instance):
        rep = super().to_representation(instance)
        request = self.context.get('request')
        if request and request.user:
            user = request.user
            if user.role == UserRole.OFFICER:
                # Mask TSP_RESPONDED status to FORWARDED so officers don't see the response state prematurely
                if rep.get('status') == RequestStatus.TSP_RESPONDED:
                    rep['status'] = RequestStatus.FORWARDED
                    rep['admin_status'] = 'Forwarded to TSP'
                
                # Officers must only see response details when the request is COMPLETED or CLOSED
                if instance.status not in [RequestStatus.COMPLETED, RequestStatus.CLOSED]:
                    rep['response'] = ''
                    rep['response_date'] = None
                    rep['tsp_response'] = None
                    rep['sms_logs'] = []
                    
                    # Filter out status logs that contain TSP_RESPONDED status
                    if 'status_logs' in rep:
                        rep['status_logs'] = [
                            log for log in rep['status_logs']
                            if log.get('status') != RequestStatus.TSP_RESPONDED
                        ]
            elif user.role == UserRole.TSP:
                # TSP representatives should only see responses if it was responded or completed/closed
                if instance.status not in [RequestStatus.TSP_RESPONDED, RequestStatus.COMPLETED, RequestStatus.CLOSED]:
                    rep['response'] = ''
                    rep['response_date'] = None
                    rep['tsp_response'] = None
                    rep['sms_logs'] = []
        return rep


class ChatMessageSerializer(serializers.ModelSerializer):
    sender_name = serializers.CharField(source='sender.username', read_only=True)
    sender_role = serializers.CharField(source='sender.role', read_only=True)
    receiver_name = serializers.CharField(source='receiver.username', read_only=True)
    receiver_role = serializers.CharField(source='receiver.role', read_only=True)

    class Meta:
        model = ChatMessage
        fields = [
            'id',
            'sender',
            'sender_name',
            'sender_role',
            'receiver',
            'receiver_name',
            'receiver_role',
            'request',
            'message',
            'timestamp'
        ]
        read_only_fields = ['sender', 'timestamp']

class PermissionSettingSerializer(serializers.ModelSerializer):
    officer_details = UserSerializer(source='officer', read_only=True)

    class Meta:
        model = PermissionSetting
        fields = ['id', 'officer', 'officer_details', 'direct_forward_allowed', 'bypass_daily_limit', 'bypass_requested', 'extra_requests_limit', 'bypass_expiry_date', 'updated_at']

class SystemNotificationSerializer(serializers.ModelSerializer):
    class Meta:
        model = SystemNotification
        fields = ['id', 'title', 'message', 'is_read', 'created_at']

class ActivityLogSerializer(serializers.ModelSerializer):
    user_name = serializers.CharField(source='user.username', read_only=True)
    user_role = serializers.CharField(source='user.role', read_only=True)
    mobile_number = serializers.CharField(source='request.mobile_number', read_only=True)

    class Meta:
        model = ActivityLog
        fields = ['id', 'action', 'user_name', 'user_role', 'request', 'mobile_number', 'details', 'timestamp']


class TspSettingSerializer(serializers.ModelSerializer):
    class Meta:
        model = TspSetting
        fields = ['id', 'tsp_name', 'forward_number', 'sms_template', 'is_active', 'created_at', 'updated_at']
        read_only_fields = ['id', 'created_at', 'updated_at']

